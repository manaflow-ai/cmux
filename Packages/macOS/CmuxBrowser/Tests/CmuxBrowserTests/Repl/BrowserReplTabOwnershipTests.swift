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

    // Two sessions' inputs in flight on one user's tab at once: WebKit does
    // not say which input a dialog, file chooser, popup or request came
    // from, so none of it goes to either session (the later one must not
    // answer the earlier one's confirm or pick its files). The dialog is
    // answered as an unhandled one, never put in front of the user.
    @Test func overlappingInputsOfTwoSessionsRouteToNeither() {
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "a")
        ownership.attach(sessionID: "b")
        ownership.setHandledEvents([.dialog, .network], for: "b")
        ownership.beginInput(sessionID: "a")
        ownership.beginInput(sessionID: "b")
        #expect(ownership.inputSessionID == nil, "no single acting session")
        #expect(ownership.recipient(for: .dialog) == nil)
        #expect(ownership.recipient(for: .fileChooser) == nil)
        // Answered as unhandled, not shown to the user.
        #expect(ownership.route(for: .dialog) == .refused)
        #expect(ownership.route(for: .fileChooser) == .refused)
        // A request either input may have started reaches only the sessions
        // that listen for network events, never the other acting session.
        let request = ownership.networkRecipients(event: "request", requestID: "1")
        #expect(request.map(\.sessionID) == ["b"])
        ownership.endInput(sessionID: "b")
        #expect(ownership.inputSessionID == "a")
        #expect(ownership.recipient(for: .dialog) == "a")
        ownership.endInput(sessionID: "a")
        #expect(ownership.recipient(for: .dialog) == "b")
        #expect(ownership.route(for: .fileChooser) == .user)
    }

    // A download in a user's tab goes to a session only when that session's
    // own input or navigation started it and it waits for downloads there:
    // a file the user downloads in their tab never reaches a session that
    // happens to listen, and a download the agent started without a
    // listener keeps the user's download location.
    @Test func aUsersTabGivesASessionOnlyTheDownloadsItsOwnInputStarted() {
        let start = ContinuousClock.now
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.attach(sessionID: "listener")
        ownership.setHandledEvents([.download], for: "agent")
        ownership.setHandledEvents([.download], for: "listener")

        // The user clicks a download link: no session's input is in flight.
        ownership.noteNavigationAction(url: "https://site.example/user.pdf", at: start)
        let userStarter = ownership.takeDownloadStarter(urls: ["https://site.example/user.pdf"], at: start)
        #expect(userStarter == nil)
        #expect(ownership.downloadRecipient(startedBy: userStarter) == nil, "the user's download stays the user's")

        // The agent clicks one.
        ownership.beginInput(sessionID: "agent")
        ownership.noteNavigationAction(url: "https://site.example/agent.pdf", at: start)
        ownership.endInput(sessionID: "agent")
        // The response arrives after the click returned.
        let agentStarter = ownership.takeDownloadStarter(urls: ["https://site.example/agent.pdf"], at: start + .seconds(2))
        #expect(agentStarter == "agent")
        #expect(ownership.downloadRecipient(startedBy: agentStarter) == "agent", "not the other listener")
        #expect(ownership.takeDownloadStarter(urls: ["https://site.example/agent.pdf"], at: start + .seconds(2)) == nil, "used once")

        // Without a listener the agent's download keeps the user's location.
        ownership.setHandledEvents([], for: "agent")
        #expect(ownership.downloadRecipient(startedBy: "agent") == nil)

        // A navigation the agent started long ago does not claim a later
        // download of the same URL the user starts.
        ownership.beginInput(sessionID: "listener")
        ownership.noteNavigationAction(url: "https://site.example/again.pdf", at: start)
        ownership.endInput(sessionID: "listener")
        #expect(ownership.takeDownloadStarter(urls: ["https://site.example/again.pdf"], at: start + .seconds(120)) == nil)
    }

    @Test func aSessionTabsDownloadsStillGoToItsCreator() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        #expect(ownership.downloadRecipient(startedBy: nil) == "creator", "every download of its own tab")
        ownership.setHandledEvents([.download], for: "creator")
        #expect(ownership.downloadRecipient(startedBy: nil) == "creator")
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
