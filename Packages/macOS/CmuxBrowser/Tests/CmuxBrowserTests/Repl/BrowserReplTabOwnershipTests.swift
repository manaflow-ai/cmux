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

    @Test func aHandlerStillWinsOverTheSessionWhoseInputOpenedTheEvent() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.attach(sessionID: "watcher")
        ownership.setHandledEvents([.dialog], for: "watcher")
        ownership.beginInput(sessionID: "agent")
        #expect(ownership.recipient(for: .dialog) == "watcher")
        #expect(ownership.recipient(for: .fileChooser) == "agent")
    }

    @Test func inputEndsWithTheSessionAndNests() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "a")
        ownership.attach(sessionID: "b")
        ownership.beginInput(sessionID: "a")
        ownership.beginInput(sessionID: "b")
        #expect(ownership.recipient(for: .dialog) == "b", "the latest input")
        ownership.endInput(sessionID: "b")
        #expect(ownership.recipient(for: .dialog) == "a")
        ownership.detach(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == nil, "a session that left gets nothing")
        // Input from a session that is not attached routes nothing.
        ownership.beginInput(sessionID: "ghost")
        #expect(ownership.recipient(for: .dialog) == nil)
    }

    @Test func eventNamesParseStrictly() {
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "filechooser", "download", "network"]) == Set(BrowserReplTabEvent.allCases))
        #expect(BrowserReplTabOwnership.events(named: []) == [])
        #expect(BrowserReplTabOwnership.events(named: ["dialog", "popup"]) == nil)
    }

    // A tab a live session created is that session's alone: another session
    // may not drive it (read its page, cookies, storage or clipboard, or
    // send it input). A user's tab, or one whose creator ended, any session
    // may drive.
    @Test func onlyItsLiveCreatorDrivesASessionsTab() {
        var ownership = BrowserReplTabOwnership()
        #expect(ownership.ownerRefusing("anyone") == nil, "a user's tab")
        ownership.markCreated(by: "creator")
        #expect(ownership.ownerRefusing("intruder") == "creator")
        #expect(ownership.ownerRefusing("creator") == nil)
        ownership.detach(sessionID: "creator")
        #expect(ownership.ownerRefusing("intruder") == nil, "a kept tab is the user's once its creator ended")
    }

    // The tab's clipboard holds what its creator copied; it is cleared when
    // the creator leaves, so a later session never reads it.
    @Test func detachSaysWhenTheCreatorLeft() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        ownership.attach(sessionID: "other")
        let other = ownership.detach(sessionID: "other")
        let creator = ownership.detach(sessionID: "creator")
        let again = ownership.detach(sessionID: "creator")
        #expect(!other)
        #expect(creator)
        #expect(!again, "only once")
    }

    // Network events carry request and response headers. They go to the
    // tab's live creator, to a session with a network listener on the tab,
    // and to the session whose input started the request; only the creator
    // sees credential headers.
    @Test func networkEventsGoOnlyToTheSessionsTheyBelongTo() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "bystander")
        ownership.attach(sessionID: "listener")
        ownership.attach(sessionID: "agent")
        ownership.setHandledEvents([.network], for: "listener")
        ownership.beginInput(sessionID: "agent")
        let started = ownership.networkRecipients(event: "request", requestID: "1")
        ownership.endInput(sessionID: "agent")
        #expect(started == [
            BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: false),
            BrowserReplNetworkRecipient(sessionID: "listener", seesCredentials: false),
        ])
        // The rest of that request follows it, after the input ended.
        let response = ownership.networkRecipients(event: "response", requestID: "1")
        let finished = ownership.networkRecipients(event: "requestfinished", requestID: "1")
        #expect(response.map(\.sessionID) == ["agent", "listener"])
        #expect(finished.map(\.sessionID) == ["agent", "listener"])
        // A later request the agent's input did not start reaches only the listener.
        let later = ownership.networkRecipients(event: "request", requestID: "2")
        #expect(later.map(\.sessionID) == ["listener"])
        ownership.setHandledEvents([], for: "listener")
        let unheard = ownership.networkRecipients(event: "request", requestID: "3")
        #expect(unheard.isEmpty)

        var created = BrowserReplTabOwnership()
        created.markCreated(by: "creator")
        let own = created.networkRecipients(event: "request", requestID: "1")
        #expect(own == [BrowserReplNetworkRecipient(sessionID: "creator", seesCredentials: true)])
    }

    @Test func credentialHeadersAreRemovedForOtherSessions() {
        let headers = [
            "cookie": "sid=1",
            "authorization": "Bearer t",
            "proxy-authorization": "Basic x",
            "set-cookie": "sid=2",
            "x-api-key": "k",
            "accept": "text/html",
        ]
        #expect(headers.removingBrowserReplCredentialHeaders() == ["accept": "text/html"])
    }
}
