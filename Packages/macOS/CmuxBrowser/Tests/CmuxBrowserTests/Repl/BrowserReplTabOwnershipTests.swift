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

    @Test func eventNamesParseStrictly() {
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "filechooser", "download"]) == Set(BrowserReplTabEvent.allCases))
        #expect(BrowserReplTabOwnership.events(named: []) == [])
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "popup"]) == nil)
    }
}
