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
        ownership.noteNavigationAction(1, frame: "main", at: start)
        let userStarter = ownership.takeDownloadStarter(navigation: 1, at: start)
        #expect(userStarter == nil)
        #expect(ownership.downloadRecipient(startedBy: userStarter) == nil, "the user's download stays the user's")

        // The agent clicks one.
        ownership.beginInput(sessionID: "agent")
        ownership.noteNavigationAction(2, frame: "main", at: start)
        ownership.endInput(sessionID: "agent")
        // A server redirect of that navigation, after the click returned.
        ownership.noteNavigationAction(3, frame: "main", continuing: true, at: start + .seconds(1))
        // The response arrives after the click returned.
        let agentStarter = ownership.takeDownloadStarter(responseInFrame: "main", at: start + .seconds(2))
        #expect(agentStarter == "agent")
        #expect(ownership.downloadRecipient(startedBy: agentStarter) == "agent", "not the other listener")
        #expect(ownership.takeDownloadStarter(responseInFrame: "main", at: start + .seconds(2)) == nil, "used once")

        // Without a listener the agent's download keeps the user's location.
        ownership.setHandledEvents([], for: "agent")
        #expect(ownership.downloadRecipient(startedBy: "agent") == nil)

        // A navigation the agent started long ago does not claim a later
        // download of the same URL the user starts.
        ownership.beginInput(sessionID: "listener")
        ownership.noteNavigationAction(4, frame: "main", at: start)
        ownership.endInput(sessionID: "listener")
        #expect(ownership.takeDownloadStarter(navigation: 4, at: start + .seconds(120)) == nil)
    }

    // The claim belongs to the navigation the session's input started, not
    // to its URL: a later navigation of the same URL that the user or the
    // page starts in the tab (no session input in flight) is the user's,
    // and so is the download it becomes.
    @Test func aLaterSameURLNavigationTheUserStartsKeepsItsDownload() {
        let start = ContinuousClock.now
        var ownership = BrowserReplTabOwnership()
        ownership.attach(sessionID: "agent")
        ownership.setHandledEvents([.download], for: "agent")
        // The agent clicks a link to report.pdf (it may never become a download).
        ownership.beginInput(sessionID: "agent")
        ownership.noteNavigationAction(1, frame: "main", at: start)
        ownership.endInput(sessionID: "agent")
        // Seconds later the user clicks a link to the same URL, which
        // becomes a download, as a navigation action or as its response.
        ownership.noteNavigationAction(2, frame: "main", at: start + .seconds(5))
        var probe = ownership
        let fromAction = probe.takeDownloadStarter(navigation: 2, at: start + .seconds(6))
        let starter = ownership.takeDownloadStarter(responseInFrame: "main", at: start + .seconds(6))
        #expect(fromAction == nil && starter == nil, "the user's same-URL download was attributed to the session")
        #expect(ownership.downloadRecipient(startedBy: starter) == nil)
        // The session's own navigation, replaced by the user's, claims nothing either.
        #expect(ownership.takeDownloadStarter(navigation: 1, at: start + .seconds(6)) == nil)
        // In another frame the session's navigation still holds.
        ownership.beginInput(sessionID: "agent")
        ownership.noteNavigationAction(5, frame: "17", at: start + .seconds(7))
        ownership.endInput(sessionID: "agent")
        ownership.noteNavigationAction(6, frame: "main", at: start + .seconds(8))
        #expect(ownership.takeDownloadStarter(navigation: 5, at: start + .seconds(9)) == "agent")
    }

    /// A download the session's input started in a user's tab reaches it
    /// with the URL's credential values replaced (a signed or bearer URL
    /// can be replayed); the creator of a tab gets its own as written.
    @Test func onlyTheCreatorSeesADownloadsURLCredentials() throws {
        var users = BrowserReplTabOwnership()
        users.attach(sessionID: "agent")
        users.setHandledEvents([.download], for: "agent")
        let delivery = try #require(users.downloadDelivery(startedBy: "agent"))
        #expect(delivery.sessionID == "agent")
        #expect(!delivery.seesCredentials, "a session saw the credentials of a download in a user's tab")
        let payload: [String: Any] = ["downloadId": "1", "url": "https://files.example/a.zip?X-Amz-Signature=s1g&token=t0k", "suggestedFilename": "a.zip"]
        let shown = try #require(payload.redactingBrowserReplCredentials()["url"] as? String)
        #expect(!shown.contains("s1g") && !shown.contains("t0k"))
        #expect(users.downloadDelivery(startedBy: nil) == nil, "the user's download stays the user's")

        var own = BrowserReplTabOwnership()
        own.markCreated(by: "creator")
        #expect(own.downloadDelivery(startedBy: nil) == BrowserReplNetworkRecipient(sessionID: "creator", seesCredentials: true))
    }

    /// A download's bytes are a read of every place its request went, so a
    /// session gets it only when its domain policy allows each of them (the
    /// navigation's URL and redirects, the download's own redirects, the
    /// response) and its local files lie inside the session's directories.
    /// In a user's tab such a download keeps the user's location; in the
    /// session's own tab it is cancelled.
    @Test func aDownloadFromAPlaceTheSessionsPolicyBlocksNeverReachesIt() throws {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse("blocked.test", title: "test")]
        let policies: (String) -> BrowserReplDomainPolicy? = { _ in policy }
        let roots: (String) -> [String]? = { _ in ["/private/tmp/agent-root"] }
        let start = ContinuousClock.now

        var users = BrowserReplTabOwnership()
        users.attach(sessionID: "agent")
        users.setHandledEvents([.download], for: "agent")
        // The agent clicks a link to an allowed page that redirects to a
        // blocked one, which answers with a file.
        users.beginInput(sessionID: "agent")
        users.noteNavigationAction(1, frame: "main", url: "https://allowed.test/get", at: start)
        users.endInput(sessionID: "agent")
        users.noteNavigationAction(2, frame: "main", url: "https://blocked.test/file.zip", continuing: true, at: start + .seconds(1))
        let taken = users.takeDownloadClaim(responseInFrame: "main", at: start + .seconds(2))
        let claim = try #require(taken)
        #expect(claim.sessionID == "agent")
        #expect(claim.source.hops == ["https://allowed.test/get", "https://blocked.test/file.zip"])
        var redirected = claim.source
        redirected.went(to: "https://blocked.test/file.zip")
        #expect(users.downloadRoute(startedBy: "agent", source: redirected, policy: policies, fileRoots: roots) == .user,
                "a download through a blocked redirect reached the session")

        // A download that only the download's own redirect sends to the blocked place.
        let viaDownload = BrowserReplDownloadSource(hops: ["https://allowed.test/a", "https://blocked.test/b", "https://allowed.test/c"])
        #expect(users.downloadRoute(startedBy: "agent", source: viaDownload, policy: policies, fileRoots: roots) == .user)
        // A local file outside the session's directories.
        let file = BrowserReplDownloadSource(hops: ["file:///etc/hosts"])
        #expect(users.downloadRoute(startedBy: "agent", source: file, policy: { _ in nil }, fileRoots: roots) == .user,
                "a local file outside the session's directories reached it as a download")
        // A data: download a blocked document wrote.
        let written = BrowserReplDownloadSource(
            hops: ["data:text/plain,hi"],
            initiator: BrowserReplFrameDocument(origin: "https://blocked.test", place: "https://blocked.test")
        )
        #expect(users.downloadRoute(startedBy: "agent", source: written, policy: policies, fileRoots: roots) == .user)
        // Allowed all the way: the session's.
        let allowed = BrowserReplDownloadSource(hops: ["https://allowed.test/get", "https://allowed.test/file.zip"])
        #expect(users.downloadRoute(startedBy: "agent", source: allowed, policy: policies, fileRoots: roots)
                == .session(BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: false)))
        let inside = BrowserReplDownloadSource(hops: ["file:///private/tmp/agent-root/out.txt"])
        #expect(users.downloadRoute(startedBy: "agent", source: inside, policy: { _ in nil }, fileRoots: roots)
                == .session(BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: false)))

        var own = BrowserReplTabOwnership()
        own.markCreated(by: "agent")
        guard case .refused = own.downloadRoute(startedBy: nil, source: viaDownload, policy: policies, fileRoots: roots) else {
            Issue.record("a blocked download in the session's own tab was not refused")
            return
        }
    }

    @Test func aSessionTabsDownloadsStillGoToItsCreator() {
        var ownership = BrowserReplTabOwnership()
        ownership.markCreated(by: "creator")
        #expect(ownership.downloadRecipient(startedBy: nil) == "creator", "every download of its own tab")
        ownership.setHandledEvents([.download], for: "creator")
        #expect(ownership.downloadRecipient(startedBy: nil) == "creator")
    }

    /// A dialog (or file chooser) a frame the session's policy blocks
    /// opened never reaches that session: it would read the blocked page's
    /// message and answer it. What the session's own doing opened is
    /// dismissed; a user's page dialog its handler would have taken goes to
    /// the user.
    @Test func aDialogFromAFrameTheSessionsPolicyBlocksNeverReachesIt() throws {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse("blocked.test", title: "test")]
        let policies: (String) -> BrowserReplDomainPolicy? = { $0 == "agent" ? policy : nil }
        let blocked = BrowserReplFrameDocument(origin: "https://blocked.test", place: "https://blocked.test")
        let allowed = BrowserReplFrameDocument(origin: "https://allowed.test", place: "https://allowed.test")

        var users = BrowserReplTabOwnership()
        users.attach(sessionID: "agent")
        users.setHandledEvents([.dialog, .fileChooser], for: "agent")
        #expect(users.route(for: .dialog, from: allowed, policy: policies) == .session("agent"))
        #expect(users.route(for: .dialog, from: blocked, policy: policies) == .user,
                "a blocked frame's dialog in a user's tab went to the session's handler")
        #expect(users.route(for: .fileChooser, from: blocked, policy: policies) == .user)
        users.beginInput(sessionID: "agent")
        #expect(users.route(for: .dialog, from: blocked, policy: policies) == .refused,
                "a blocked frame's dialog during the session's input reached it or the user")
        users.endInput(sessionID: "agent")

        var own = BrowserReplTabOwnership()
        own.markCreated(by: "agent")
        #expect(own.route(for: .dialog, from: blocked, policy: policies) == .refused,
                "a blocked frame's dialog in the session's own tab reached it")
        #expect(own.route(for: .dialog, from: allowed, policy: policies) == .session("agent"))

        // Another session's policy does not matter.
        var other = BrowserReplTabOwnership()
        other.attach(sessionID: "free")
        other.setHandledEvents([.dialog], for: "free")
        #expect(other.route(for: .dialog, from: blocked, policy: policies) == .session("free"))
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

    /// Sites carry credentials in custom headers too. Network events for a
    /// session that did not create the tab drop every header whose name says
    /// it carries one, as `fetch` does across origins, and keep the rest.
    @Test func customCredentialHeadersAreRemovedForOtherSessions() {
        let headers = [
            "x-session-token": "s",
            "x-secret": "s",
            "x-password": "p",
            "x-signature": "sig",
            "x-amz-security-token": "t",
            "x-client-credential": "c",
            "x-goog-authuser": "0",
            "x-apikey": "k",
            "www-authenticate": "Bearer",
            "x-request-id": "r",
            "content-type": "text/html",
        ]
        #expect(headers.removingBrowserReplCredentialHeaders() == ["x-request-id": "r", "content-type": "text/html"])
    }
    /// A request's URL can carry a credential too: an OAuth code or token
    /// in a callback, a signed URL's signature, a reset token, a password
    /// in the userinfo. A session that did not create the tab gets the URL
    /// with those values replaced, by the header rule's names plus the
    /// usual query names (`code`, `sig`, `key` and the like), also in the
    /// URL-valued headers (`location`, `referer`).
    @Test func credentialValuesInURLsAreRedactedForOtherSessions() throws {
        let payload: [String: Any] = [
            "requestId": "1",
            "url": "https://user:hunter2@app.example/cb?code=abc123&state=xyz&access_token=t0k&X-Amz-Signature=s1g&sig=s2&page=2#id_token=jwt",
            "method": "GET",
            "headers": [
                "location": "https://app.example/next?refresh_token=r3f&view=full",
                "referer": "https://login.example/reset?reset_token=rst&lang=en",
                "accept": "text/html",
                "cookie": "sid=1",
            ],
        ]
        let redacted = payload.redactingBrowserReplCredentials()
        let url = try #require(redacted["url"] as? String)
        let headers = try #require(redacted["headers"] as? [String: String])
        for secret in ["hunter2", "abc123", "t0k", "s1g", "s2", "jwt", "r3f", "rst", "sid=1"] {
            #expect(!url.contains(secret) && !headers.values.contains { $0.contains(secret) }, "\(secret) reached another session")
        }
        for kept in ["state=xyz", "page=2", "app.example/cb"] {
            #expect(url.contains(kept), "\(kept) was lost")
        }
        #expect(headers["location"]?.contains("view=full") == true)
        #expect(headers["referer"]?.contains("lang=en") == true)
        #expect(headers["accept"] == "text/html")
        #expect(redacted["method"] as? String == "GET")
    }

    @Test func aURLWithoutCredentialsIsUnchanged() {
        let payload: [String: Any] = ["url": "https://app.example/search?q=tea&page=2"]
        #expect(payload.redactingBrowserReplCredentials()["url"] as? String == "https://app.example/search?q=tea&page=2")
    }

    /// A configured external-open rule hands an activated link to the
    /// user's system browser (NSWorkspace), outside the tab, its domain
    /// policy and cmux. An agent's synthesized click is a link activation
    /// to WebKit, and a page can activate a link itself (`a.click()`), so in
    /// a tab sessions drive only a link the user activates, in a user's tab
    /// they are working in, may leave; any other loads in the tab.
    @Test func onlyTheUsersOwnLinkActivationsGoToTheExternalBrowser() {
        var users = BrowserReplTabOwnership()
        users.attach(sessionID: "agent")
        #expect(users.handsLinksToExternalBrowser(userIsWorkingInTab: true))
        #expect(!users.handsLinksToExternalBrowser(userIsWorkingInTab: false),
                "a link activated in a tab sessions drive while the user works elsewhere left cmux")

        users.beginInput(sessionID: "agent")
        #expect(!users.handsLinksToExternalBrowser(userIsWorkingInTab: true),
                "an agent's click handed a link to the external browser")
        users.endInput(sessionID: "agent")
        #expect(users.handsLinksToExternalBrowser(userIsWorkingInTab: true))

        var own = BrowserReplTabOwnership()
        own.markCreated(by: "agent")
        #expect(!own.handsLinksToExternalBrowser(userIsWorkingInTab: true),
                "a link in a tab a session created left its domain policy for the external browser")
        own.attach(sessionID: "other")
        own.detach(sessionID: "agent")
        #expect(own.handsLinksToExternalBrowser(userIsWorkingInTab: true),
                "a tab its creator left is the user's")
    }
    /// A page activates links itself (`a.click()` from its own script or
    /// from agent-world code the session ran, which holds no input), and
    /// WebKit reports that as a link activation too. In a tab a session
    /// drives, only an activation WebKit marks as the user's gesture goes
    /// to the external browser, and not while a gesture a session's input
    /// gave the page may still be used.
    @Test func aPagesOwnLinkActivationInADrivenTabStaysInTheTab() {
        var users = BrowserReplTabOwnership()
        users.attach(sessionID: "agent")
        let start = ContinuousClock.now
        let page = BrowserReplLinkActivation(userIsWorkingInTab: true, isUserInitiated: false)
        let user = BrowserReplLinkActivation(userIsWorkingInTab: true, isUserInitiated: true)
        #expect(!users.handsLinkToExternalBrowser(page, now: start),
                "a page's own link activation in a tab a session drives went to the external browser")
        #expect(users.handsLinkToExternalBrowser(user, now: start))

        // After the agent's input the page may still hold its gesture.
        users.beginInput(sessionID: "agent")
        users.endInput(sessionID: "agent", at: start)
        #expect(!users.handsLinkToExternalBrowser(user, now: start.advanced(by: .seconds(5))),
                "a link the page activated with the agent's lingering gesture went to the external browser")
        #expect(users.handsLinkToExternalBrowser(user, now: start.advanced(by: BrowserReplTabOwnership.agentGestureLingering)))
    }
}
