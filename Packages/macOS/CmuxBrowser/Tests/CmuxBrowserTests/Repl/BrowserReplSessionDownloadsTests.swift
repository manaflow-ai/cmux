import Testing
@testable import CmuxBrowser

/// A download that went to a session is a read of every place its request
/// went. The decision made when WebKit picked its destination must hold
/// until the session gets the file: a redirect WebKit reports later, or a
/// domain policy the session locked tighter since, takes the download away
/// from the session before `download.finished` names its path.
@Suite struct BrowserReplSessionDownloadsTests {
    private static func roots(_ sessionID: String) -> [String]? { ["/private/tmp/agent-root"] }

    private static func blocking(_ host: String) throws -> (String) -> BrowserReplDomainPolicy? {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse(host, title: "test")]
        return { _ in policy }
    }

    private static let creator = BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: true)

    private static let allowed = BrowserReplDownloadSource(hops: ["https://allowed.test/get", "https://allowed.test/file.zip"])

    /// A session's unfinished downloads end with it: teardown hands back
    /// their ids so cmux cancels them and removes their partial files. They
    /// never stay for a later finish, which would find no session and give
    /// the file to the user's download location or save panel.
    @Test func aSessionThatLeavesHandsBackItsUnfinishedDownloads() {
        var downloads = BrowserReplSessionDownloads()
        let other = BrowserReplNetworkRecipient(sessionID: "other", seesCredentials: false)
        downloads.add("d1", to: Self.creator, source: Self.allowed)
        downloads.add("d2", to: other, source: Self.allowed)
        downloads.add("d3", to: Self.creator, source: Self.allowed)

        #expect(Set(downloads.sessionLeft("agent")) == ["d1", "d3"])
        #expect(downloads.sessionID(of: "d1") == nil)
        #expect(downloads.sessionID(of: "d3") == nil)
        #expect(downloads.sessionID(of: "d2") == "other", "another session's download left with the leaving session")
        #expect(downloads.sessionLeft("agent").isEmpty)

        // The tab's last session leaving (or the tab closing) hands back the rest.
        #expect(downloads.removeAll() == ["d2"])
        #expect(downloads.sessionID(of: "d2") == nil)
    }

    /// A download's route is one record, decided when WebKit picks its
    /// destination, that its redirects and its end read. A download that
    /// went to a session whose session left before it ended (its teardown
    /// took the ledger entry, or the tab's attachment is gone) is cancelled:
    /// the missing session never makes it look like the user's.
    @Test func aSessionsDownloadEndsCancelledOnceItsSessionLeftNeverTheUsers() throws {
        let roots: (String) -> [String]? = Self.roots
        var claim = BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed)
        claim.decide(.session(Self.creator))
        claim.decide(.user)
        #expect(claim.route == .session(Self.creator), "a later decision replaced the recorded route")

        var downloads = BrowserReplSessionDownloads()
        downloads.add("d1", to: Self.creator, source: Self.allowed)
        _ = downloads.sessionLeft("agent")
        #expect(claim.end(downloads.finish("d1", policy: { _ in nil }, fileRoots: roots)) == .cancelled,
                "a departed session's download went to the user")
        #expect(claim.end(nil) == .cancelled, "a download of a tab whose attachment is gone went to the user")

        // The live session gets its file.
        downloads.add("d2", to: Self.creator, source: Self.allowed)
        #expect(claim.end(downloads.finish("d2", policy: { _ in nil }, fileRoots: roots)) == .session)

        // A refusal at the end: the creator's tab removes the file; a
        // session's download in a user's tab keeps the user's location.
        let blocked = try Self.blocking("allowed.test")
        downloads.add("d3", to: Self.creator, source: Self.allowed)
        #expect(claim.end(downloads.finish("d3", policy: blocked, fileRoots: roots)) == .refused)
        let visitor = BrowserReplNetworkRecipient(sessionID: "visitor", seesCredentials: false)
        var inUsersTab = BrowserReplDownloadClaim(sessionID: "visitor", source: Self.allowed)
        inUsersTab.decide(.session(visitor))
        downloads.add("d4", to: visitor, source: Self.allowed)
        #expect(inUsersTab.end(downloads.finish("d4", policy: blocked, fileRoots: roots)) == .user)

        // The user's download is the user's whatever the sessions do; one a
        // session's input started that was never routed goes nowhere.
        var users = BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed)
        users.decide(.user)
        #expect(users.end(nil) == .user)
        #expect(BrowserReplDownloadClaim(sessionID: "agent", source: Self.allowed).end(nil) == .cancelled)
        #expect(BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed).end(nil) == .user)
        var cancelled = BrowserReplDownloadClaim(sessionID: "agent", source: Self.allowed)
        cancelled.decide(.cancelled)
        #expect(cancelled.end(nil) == .cancelled)
    }

    /// A redirect WebKit reports after the start reads the recorded route,
    /// never the tab's current sessions: a session's download whose session
    /// left is cancelled, and one its session's policy refuses there leaves
    /// that session (cancelled in its own tab, the user's in a user's tab).
    @Test func aRedirectAfterTheStartReadsTheRecordedRoute() {
        var gone = BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed)
        gone.decide(.session(Self.creator))
        let followed1 = gone.redirect(.gone)
        #expect(!followed1, "a departed session's download followed a redirect")
        #expect(gone.route == .cancelled)

        var own = BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed)
        own.decide(.session(Self.creator))
        let followed2 = own.redirect(.keeps)
        #expect(followed2)
        #expect(own.route == .session(Self.creator))
        let followed3 = own.redirect(.refuses)
        #expect(!followed3)
        #expect(own.route == .cancelled)

        let visitor = BrowserReplNetworkRecipient(sessionID: "visitor", seesCredentials: false)
        var inUsersTab = BrowserReplDownloadClaim(sessionID: "visitor", source: Self.allowed)
        inUsersTab.decide(.session(visitor))
        let followed4 = inUsersTab.redirect(.refuses)
        #expect(followed4)
        #expect(inUsersTab.route == .user)

        var users = BrowserReplDownloadClaim(sessionID: nil, source: Self.allowed)
        users.decide(.user)
        let followed5 = users.redirect(.gone)
        #expect(followed5, "the user's download was cancelled for a session's sake")
        #expect(users.route == .user)
    }

    @Test func aLaterRedirectToABlockedPlaceTakesTheDownloadAway() throws {
        let policy = try Self.blocking("blocked.test")
        var downloads = BrowserReplSessionDownloads()
        downloads.add("d1", to: Self.creator, source: Self.allowed)
        #expect(downloads.redirect("d1", to: "https://allowed.test/mirror", policy: policy, fileRoots: Self.roots) == nil)
        #expect(downloads.sessionID(of: "d1") == "agent")

        let refusal = downloads.redirect("d1", to: "https://blocked.test/file.zip", policy: policy, fileRoots: Self.roots)
        #expect(refusal?.sessionID == "agent", "a redirect to a blocked place left the download with the session")
        #expect(downloads.sessionID(of: "d1") == nil)
        #expect(downloads.finish("d1", policy: policy, fileRoots: Self.roots) == .notSessions,
                "a download taken away by its redirect still delivered its path")
    }

    @Test func aLaterRedirectToALocalFileOutsideTheSessionsDirectoriesTakesTheDownloadAway() {
        var downloads = BrowserReplSessionDownloads()
        downloads.add("d2", to: Self.creator, source: Self.allowed)
        let refusal = downloads.redirect("d2", to: "file:///etc/hosts", policy: { _ in nil }, fileRoots: Self.roots)
        #expect(refusal?.sessionID == "agent")
        #expect(downloads.finish("d2", policy: { _ in nil }, fileRoots: Self.roots) == .notSessions)
    }

    /// The finish judges every place again under the session's policy now.
    @Test func theDownloadIsJudgedAgainWhenItFinishes() throws {
        var downloads = BrowserReplSessionDownloads()
        downloads.add("d3", to: Self.creator, source: Self.allowed)
        let tightened = try Self.blocking("allowed.test")
        guard case .refused(let sessionID, _) = downloads.finish("d3", policy: tightened, fileRoots: Self.roots) else {
            Issue.record("a download from a place the session's policy blocks by its end delivered its path")
            return
        }
        #expect(sessionID == "agent")

        downloads.add("d4", to: Self.creator, source: Self.allowed)
        #expect(downloads.finish("d4", policy: try Self.blocking("blocked.test"), fileRoots: Self.roots) == .session("agent"))
        #expect(downloads.finish("d4", policy: { _ in nil }, fileRoots: Self.roots) == .notSessions, "a download finished twice")
    }

    /// A session that did not create the tab (one whose own input started a
    /// download in a user's tab) gets its downloads' URLs with their
    /// credential values replaced, so a refusal must not name a place the
    /// download went as written: a signed redirect's signature, a token in
    /// its query, a password in its userinfo.
    @Test func aRefusalReachesASessionThatDidNotCreateTheTabWithoutTheURLsCredentials() throws {
        let secrets = ["pw-secret", "sig-secret", "tok-secret"]
        let signed = "https://user:pw-secret@blocked.test/file.zip?X-Amz-Signature=sig-secret&access_token=tok-secret"
        let agent = BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: false)
        var downloads = BrowserReplSessionDownloads()

        downloads.add("d5", to: agent, source: Self.allowed)
        let redirectedRefusal = downloads.redirect("d5", to: signed, policy: try Self.blocking("blocked.test"), fileRoots: Self.roots)
        let redirected = try #require(redirectedRefusal)
        #expect(redirected.reason.contains("blocked.test"), "the refusal no longer names the refused host")
        for secret in secrets {
            #expect(!redirected.reason.contains(secret), "a redirect's refusal gave a non-creator \(secret)")
        }

        downloads.add("d6", to: agent, source: Self.allowed)
        let localRefusal = downloads.redirect("d6", to: "file:///etc/hosts?token=tok-secret", policy: { _ in nil }, fileRoots: Self.roots)
        let local = try #require(localRefusal)
        #expect(!local.reason.contains("tok-secret"), "a local file's refusal gave a non-creator the URL as written")

        downloads.add("d7", to: agent, source: BrowserReplDownloadSource(hops: [signed.replacingOccurrences(of: "blocked.test", with: "allowed.test")]))
        guard case .refused(_, let reason) = downloads.finish("d7", policy: try Self.blocking("allowed.test"), fileRoots: Self.roots) else {
            Issue.record("a download from a place the session's policy blocks by its end delivered its path")
            return
        }
        for secret in secrets {
            #expect(!reason.contains(secret), "the end's refusal gave a non-creator \(secret)")
        }

        // The tab's creator reads its own downloads' URLs as written.
        downloads.add("d8", to: BrowserReplNetworkRecipient(sessionID: "agent", seesCredentials: true), source: Self.allowed)
        let ownRefusal = downloads.redirect("d8", to: signed, policy: try Self.blocking("blocked.test"), fileRoots: Self.roots)
        let own = try #require(ownRefusal)
        #expect(own.reason.contains("sig-secret"))
    }
}
