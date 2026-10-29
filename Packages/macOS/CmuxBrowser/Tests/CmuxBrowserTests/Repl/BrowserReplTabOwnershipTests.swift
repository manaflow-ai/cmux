import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserReplTabOwnershipTests {
    @Test func aTabNoSessionCreatedKeepsTheUsersUI() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        #expect(!ownership.isSessionOwned)
        for event in BrowserReplTabEvent.allCases {
            #expect(!ownership.routesToSessions(event))
        }
    }

    @Test func aTabTheSessionCreatedRoutesEverythingToIt() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "agent")
        #expect(ownership.isSessionOwned)
        for event in BrowserReplTabEvent.allCases {
            #expect(ownership.routesToSessions(event))
        }
    }

    @Test func aHandlerOnAUsersTabTakesOnlyItsEvent() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.setHandledEvents([.dialog], for: "agent")
        #expect(ownership.routesToSessions(.dialog))
        #expect(!ownership.routesToSessions(.fileChooser))
        #expect(!ownership.routesToSessions(.download))
        #expect(!ownership.isSessionOwned)
        ownership.setHandledEvents([], for: "agent")
        #expect(!ownership.routesToSessions(.dialog))
    }

    @Test func handlersEndWithTheirSession() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "a")
        ownership.attach(sessionID: "b")
        ownership.setHandledEvents([.download], for: "a")
        ownership.detach(sessionID: "a")
        #expect(!ownership.routesToSessions(.download))
        // A session that is not attached cannot register handlers.
        ownership.setHandledEvents([.download], for: "a")
        #expect(!ownership.routesToSessions(.download))
    }

    @Test func theTabIsTheUsersOnceItsCreatorLeaves() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        ownership.attach(sessionID: "other")
        ownership.detach(sessionID: "creator")
        #expect(!ownership.isSessionOwned)
        #expect(!ownership.routesToSessions(.dialog))
        #expect(ownership.creatorSessionID == nil)
    }

    // One session gets each routed event, so only that session can answer it.
    @Test func aRoutedEventGoesToOneSession() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "first")
        ownership.attach(sessionID: "second")
        ownership.setHandledEvents([.dialog], for: "first")
        ownership.setHandledEvents([.dialog, .download], for: "second")
        #expect(ownership.recipient(for: .dialog) == "first", "the session that registered first")
        #expect(ownership.recipient(for: .download) == "second")
        #expect(ownership.recipient(for: .fileChooser) == nil, "the user's UI")
        // A session that drives the tab without a handler gets none of them.
        ownership.attach(sessionID: "bystander")
        #expect(ownership.recipient(for: .dialog) == "first")
        ownership.setHandledEvents([], for: "first")
        #expect(ownership.recipient(for: .dialog) == "second")
        ownership.detach(sessionID: "second")
        #expect(ownership.recipient(for: .dialog) == nil)
    }

    @Test func aSessionTabsEventsGoToItsCreatorUnlessAnotherSessionHandlesThem() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        ownership.attach(sessionID: "other")
        #expect(ownership.recipient(for: .dialog) == "creator")
        ownership.setHandledEvents([.dialog], for: "other")
        #expect(ownership.recipient(for: .dialog) == "other", "a handler takes the event")
        ownership.setHandledEvents([.dialog], for: "creator")
        #expect(ownership.recipient(for: .dialog) == "creator", "the creator's handler first")
        #expect(ownership.recipient(for: .download) == "creator")
    }

    // An agent's click in a user's tab that opens an alert or a file panel
    // must not put cmux's UI in front of the user (a file panel opened over
    // their work from a hidden workspace) or hang the agent on a dialog only
    // the user can see. What the agent's own input opens goes to the agent.
    @Test func whatASessionsInputOpensInAUsersTabGoesToThatSession() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.attach(sessionID: "other")
        ownership.beginInput(sessionID: "agent")
        #expect(ownership.recipient(for: .dialog) == "agent")
        #expect(ownership.recipient(for: .fileChooser) == "agent")
        #expect(ownership.recipient(for: .download) == nil, "a download keeps the user's download location")
        #expect(!ownership.isSessionOwned, "the tab stays the user's")
        ownership.endInput(sessionID: "agent")
        #expect(ownership.recipient(for: .dialog) == nil, "after the input, the user's UI again")
        #expect(ownership.recipient(for: .fileChooser) == nil)
    }

    // A dialog or file chooser the page opens while it handles one
    // session's input is that session's doing: another session's handler
    // on the user's tab must not answer it (accept a confirm, pick files).
    @Test func theSessionWhoseInputOpenedTheEventWinsOverAnotherSessionsHandler() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.attach(sessionID: "watcher")
        ownership.setHandledEvents([.dialog, .fileChooser], for: "watcher")
        ownership.beginInput(sessionID: "agent")
        #expect(ownership.recipient(for: .dialog) == "agent")
        #expect(ownership.recipient(for: .fileChooser) == "agent")
        ownership.endInput(sessionID: "agent")
        #expect(ownership.recipient(for: .dialog) == "watcher", "the page's own dialog goes to the handler")
    }

    @Test func inputEndsWithTheSessionAndNests() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "a")
        ownership.attach(sessionID: "b")
        ownership.beginInput(sessionID: "a")
        ownership.beginInput(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == "a", "one session's nested inputs")
        ownership.endInput(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == "a")
        ownership.endInput(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == nil)
        ownership.beginInput(sessionID: "a")
        ownership.detach(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == nil, "a session that left gets nothing")
        // Input from a session that is not attached routes nothing.
        ownership.beginInput(sessionID: "ghost")
        #expect(ownership.recipient(for: .dialog) == nil)
    }

    /// Whether `route` ends the download with nobody getting the file: not
    /// the user's location, and no session.
    private static func cancels(_ route: BrowserReplDownloadRoute) -> Bool {
        switch route {
        case .user, .session: false
        default: true
        }
    }

    @Test func eventNamesParseStrictly() {
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "filechooser", "download", "network"]) == Set(BrowserReplTabEvent.allCases))
        #expect(BrowserReplTabOwnership.events(named: []) == [])
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "popup"]) == nil)
    }

}
