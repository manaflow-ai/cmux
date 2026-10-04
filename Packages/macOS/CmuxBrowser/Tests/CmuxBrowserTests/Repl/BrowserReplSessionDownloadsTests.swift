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

    private static let allowed = BrowserReplDownloadSource(hops: ["https://allowed.test/get", "https://allowed.test/file.zip"])

    @Test func aLaterRedirectToABlockedPlaceTakesTheDownloadAway() throws {
        let policy = try Self.blocking("blocked.test")
        var downloads = BrowserReplSessionDownloads()
        downloads.add("d1", sessionID: "agent", source: Self.allowed)
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
        downloads.add("d2", sessionID: "agent", source: Self.allowed)
        let refusal = downloads.redirect("d2", to: "file:///etc/hosts", policy: { _ in nil }, fileRoots: Self.roots)
        #expect(refusal?.sessionID == "agent")
        #expect(downloads.finish("d2", policy: { _ in nil }, fileRoots: Self.roots) == .notSessions)
    }

    /// The finish judges every place again under the session's policy now.
    @Test func theDownloadIsJudgedAgainWhenItFinishes() throws {
        var downloads = BrowserReplSessionDownloads()
        downloads.add("d3", sessionID: "agent", source: Self.allowed)
        let tightened = try Self.blocking("allowed.test")
        guard case .refused(let sessionID, _) = downloads.finish("d3", policy: tightened, fileRoots: Self.roots) else {
            Issue.record("a download from a place the session's policy blocks by its end delivered its path")
            return
        }
        #expect(sessionID == "agent")

        downloads.add("d4", sessionID: "agent", source: Self.allowed)
        #expect(downloads.finish("d4", policy: try Self.blocking("blocked.test"), fileRoots: Self.roots) == .session("agent"))
        #expect(downloads.finish("d4", policy: { _ in nil }, fileRoots: Self.roots) == .notSessions, "a download finished twice")
    }
}
