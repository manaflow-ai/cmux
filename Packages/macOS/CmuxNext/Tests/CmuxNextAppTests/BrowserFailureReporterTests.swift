import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextCrashReporting
import Foundation
import Testing

/// Renderer ends (the sad tab) and main-frame load failures reach crash
/// reporting as one event each, deduplicated, with the site reduced to its
/// scheme and host.
@Suite struct BrowserFailureReporterTests {
    private static let versions = BrowserEngineVersions(cef: "156.0.15", chromium: "156.0.8078.80", forkAPI: 24)
    /// A page address with a user, port, path, query and fragment: only scheme and host may leave.
    private static let page = URL(string: "https://me@docs.example.com:8443/private/notes?token=abc#frag")

    @Test func rendererTerminatedSendsOneErrorEventWithSchemeAndHostOnly() throws {
        let sent = FailureRecorder()
        let reporter = BrowserFailureReporter(isEnabled: { true }, sink: { sent.add($0) })
        // CEF: TS_PROCESS_CRASHED (2), waitpid status 5 (SIGTRAP), the V8 code range OOM of the NIGHTLY report.
        reporter.note(.rendererTerminated(status: 2, code: 5, text: "Failed to reserve virtual memory for CodeRange",
                                          url: Self.page, versions: Self.versions))
        let events = sent.events
        #expect(events.count == 1)
        let failure = try #require(events.first)
        #expect(failure.count == 1)
        let event = failure.event()
        #expect(event.level == .error)
        #expect(event.exceptions?.first?.type == "RendererProcessTerminated")
        #expect(event.exceptions?.first?.value == "renderer crashed SIGTRAP")
        #expect(event.fingerprint == ["browser_failure", "renderer_terminated", "crashed", "SIGTRAP"])
        #expect(event.tags == [
            "browser_failure": "renderer_terminated",
            "termination_status": "crashed",
            "error_code": "5",
            "error_name": "SIGTRAP",
            "process_kind": "renderer",
            "site": "https://docs.example.com",
            "cef_version": "156.0.15",
            "chromium_version": "156.0.8078.80",
            "cef_fork_api": "24",
        ])
        #expect(event.extra?["count"] as? Int == 1)
        #expect(event.extra?["reason"] as? String == "Failed to reserve virtual memory for CodeRange")
        let everything = "\(event.tags ?? [:]) \(event.extra ?? [:]) \(event.exceptions?.first?.value ?? "")"
        for secret in ["private", "notes", "token", "abc", "frag", "8443", "me@"] {
            #expect(!everything.contains(secret), "page detail \(secret) left the app")
        }
    }

    @Test(arguments: [
        (1, "killed", nil as String?),
        (3, "outOfMemory", nil),
        (4, "launchFailed", nil),
        (5, "integrityFailure", nil),
        (0, "abnormal", "exit 3"),
    ])
    func everyTerminationStatusIsNamed(status: Int, name: String, codeName: String?) throws {
        let failure = BrowserEngineFailure.rendererTerminated(status: status, code: status == 0 ? 3 << 8 : 0, text: "",
                                                              url: Self.page)
        let tags = BrowserFailureEvent(failure: failure).event().tags
        #expect(tags?["termination_status"] == name)
        #expect(tags?["error_name"] == codeName)
    }

    @Test func loadErrorSendsAWarningWithTheNetErrorName() throws {
        let sent = FailureRecorder()
        let reporter = BrowserFailureReporter(isEnabled: { true }, sink: { sent.add($0) })
        reporter.note(.loadFailed(code: -105, name: "net::ERR_NAME_NOT_RESOLVED", url: Self.page, interstitial: false,
                                  versions: Self.versions))
        reporter.note(.loadFailed(code: -202, name: "net::ERR_CERT_AUTHORITY_INVALID", url: URL(string: "https://self-signed.test/x"),
                                  interstitial: true))
        let events = sent.events.map { $0.event() }
        #expect(events.count == 2)
        let dns = try #require(events.first)
        #expect(dns.level == .warning)
        #expect(dns.exceptions?.first?.type == "MainFrameLoadFailed")
        #expect(dns.exceptions?.first?.value == "ERR_NAME_NOT_RESOLVED (-105)")
        #expect(dns.fingerprint == ["browser_failure", "load_failed", "-", "ERR_NAME_NOT_RESOLVED"])
        #expect(dns.tags?["error_name"] == "ERR_NAME_NOT_RESOLVED")
        #expect(dns.tags?["error_code"] == "-105")
        #expect(dns.tags?["interstitial"] == "no")
        #expect(dns.tags?["site"] == "https://docs.example.com")
        #expect(dns.tags?["termination_status"] == nil)
        #expect(dns.tags?["process_kind"] == nil)
        let certificate = try #require(events.last)
        #expect(certificate.tags?["interstitial"] == "yes")
        #expect(certificate.exceptions?.first?.value == "ERR_CERT_AUTHORITY_INVALID (-202) interstitial")
        #expect(certificate.tags?["site"] == "https://self-signed.test")
    }

    @Test func cancelledLoadsAreNeverSent() {
        let reporter = BrowserFailureReporter(isEnabled: { true }, sink: { _ in Issue.record("a cancelled load was sent") })
        #expect(reporter.note(.loadFailed(code: -3, name: "net::ERR_ABORTED", url: Self.page, interstitial: false)) == nil)
        #expect(reporter.note(.loadFailed(code: -3, name: "", url: Self.page, interstitial: false)) == nil)
        #expect(reporter.note(.loadFailed(code: 0, name: "", url: Self.page, interstitial: false)) == nil)
    }

    @Test func aCrashLoopSendsAFewEventsWithACount() {
        let sent = FailureRecorder()
        let reporter = BrowserFailureReporter(isEnabled: { true }, sink: { sent.add($0) })
        let crash = BrowserEngineFailure.rendererTerminated(status: 2, code: 5, text: "", url: Self.page)
        for _ in 0..<668 { reporter.note(crash) }
        #expect(sent.events.map(\.count) == [1, 10, 100])
        #expect(sent.events.last?.event().extra?["count"] as? Int == 100)
        // The same crash on another site, and another signal on this one, are new keys: sent at once.
        reporter.note(.rendererTerminated(status: 2, code: 5, text: "", url: URL(string: "https://other.example")))
        reporter.note(.rendererTerminated(status: 2, code: 11, text: "", url: Self.page))
        #expect(sent.events.map(\.count) == [1, 10, 100, 1, 1])
    }

    @Test func theThrottleCountsAtMostMaxKeys() {
        var throttle = BrowserFailureThrottle(maxKeys: 2)
        #expect(throttle.admit("a") == 1)
        #expect(throttle.admit("b") == 1)
        #expect(throttle.admit("c") == nil, "a third key is not counted")
        let counts = (2...10).map { _ in throttle.admit("a") }
        #expect(counts.compactMap { $0 } == [10])
    }

    @Test func nothingIsSentWhileReportingIsOff() {
        let reporter = BrowserFailureReporter(isEnabled: { false }, sink: { _ in Issue.record("sent while off") })
        #expect(reporter.note(.rendererTerminated(status: 2, code: 11, text: "", url: Self.page)) == nil)
    }

    @Test func siteKeepsOnlySchemeAndHost() {
        #expect(BrowserEngineFailure.site(of: URL(string: "HTTPS://User:pw@Example.COM:8443/a/b?c=d#e")) == "https://example.com")
        #expect(BrowserEngineFailure.site(of: URL(string: "about:blank")) == "about:")
        #expect(BrowserEngineFailure.site(of: URL(fileURLWithPath: "/Users/someone/secret.html")) == "file:")
        #expect(BrowserEngineFailure.site(of: nil) == nil)
    }

    @Test func versionsComeFromCEFVersionInfo() {
        let entries: [Int32: Int32] = [0: 156, 1: 0, 2: 15, 3: 9, 4: 156, 5: 0, 6: 8078, 7: 80]
        let versions = BrowserEngineVersions.cef(info: { entries[$0] ?? 0 }, forkAPI: 24)
        #expect(versions == BrowserEngineVersions(cef: "156.0.15", chromium: "156.0.8078.80", forkAPI: 24))
        #expect(BrowserEngineVersions.cef(info: { _ in 0 }, forkAPI: 0) == BrowserEngineVersions())
    }
}

/// Collects sent failures; the reporter's sink runs on the caller, so reads are immediate.
private nonisolated final class FailureRecorder: Sendable {
    private let sent = Mutex<[BrowserFailureEvent]>([])
    func add(_ event: BrowserFailureEvent) { sent.withLock { $0.append(event) } }
    var events: [BrowserFailureEvent] { sent.withLock { $0 } }
}
