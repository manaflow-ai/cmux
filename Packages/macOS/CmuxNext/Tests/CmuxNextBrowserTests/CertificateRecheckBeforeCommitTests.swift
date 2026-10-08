import Foundation
import Testing
@testable import CmuxNextBrowser

/// After "Turn on warnings", the host's next page is checked before it
/// commits (the navigation action policy waits for the check), so the old
/// page never shows before the warning. The check at commit let the page
/// show for a moment (nxbp15-v1).
@MainActor
@Suite(.serialized)
struct CertificateRecheckBeforeCommitTests {
    private let host = "self-signed.test"
    private var page: URL { URL(string: "https://\(host)/")! }

    private final class Decisions {
        var values: [Bool] = []
    }

    /// An engine whose host `host` is being rechecked in the default
    /// profile, and whose probe answers only when the test yields a result.
    private func engine() -> (WebKitEngine, AsyncStream<CertificateProbeResult>.Continuation) {
        let engine = WebKitEngine()
        let (results, answer) = AsyncStream.makeStream(of: CertificateProbeResult.self)
        engine.certificateProbe = { _ in
            for await result in results { return result }
            return .unknown
        }
        engine.allowCertificateException(host: host, profile: .default)
        engine.forgetCertificateException(host: host, profile: .default)
        return (engine, answer)
    }

    private func settle(_ decisions: Decisions) async {
        for _ in 0 ..< 200 where decisions.values.isEmpty { await Task.yield() }
    }

    @Test func thePageDoesNotCommitBeforeTheCheckAnswers() async {
        let (engine, answer) = engine()
        let tab = engine.makeWebKitTab(profile: .default)
        let decisions = Decisions()
        engine.admitMainFrameLoad(page, in: tab) { decisions.values.append($0) }
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(decisions.values.isEmpty, "the policy decision waits for the check: no commit, no flash")

        answer.yield(.untrusted(chain: [], reason: "self-signed"))
        await settle(decisions)
        #expect(decisions.values == [false], "an untrusted host's page is cancelled before it commits")
        #expect(tab.state.loadError?.isCertificateError == true, "the interstitial shows")
        #expect(tab.state.loadError?.failingURL == page)
        #expect(engine.needsCertificateRecheck(host, profile: .default), "still rechecked until it passes or Proceed")
    }

    @Test func aTrustedHostLoadsAndEndsTheRecheck() async {
        let (engine, answer) = engine()
        let tab = engine.makeWebKitTab(profile: .default)
        let decisions = Decisions()
        engine.admitMainFrameLoad(page, in: tab) { decisions.values.append($0) }
        answer.yield(.trusted)
        await settle(decisions)
        #expect(decisions.values == [true])
        #expect(tab.state.loadError == nil)
        #expect(!engine.needsCertificateRecheck(host, profile: .default))
    }

    @Test func anUnknownResultLoadsButKeepsTheRecheck() async {
        let (engine, answer) = engine()
        let tab = engine.makeWebKitTab(profile: .default)
        let decisions = Decisions()
        engine.admitMainFrameLoad(page, in: tab) { decisions.values.append($0) }
        answer.yield(.unknown)
        await settle(decisions)
        #expect(decisions.values == [true], "WebKit's own TLS check still runs on a new connection")
        #expect(engine.needsCertificateRecheck(host, profile: .default))
    }

    /// Hosts that are not rechecked, and plain http, load at once: the
    /// probe (which would say untrusted) is never asked.
    @Test func otherLoadsAreNotHeld() {
        let (engine, answer) = engine()
        answer.yield(.untrusted(chain: [], reason: "would block"))
        let tab = engine.makeWebKitTab(profile: .default)
        let decisions = Decisions()
        engine.admitMainFrameLoad(URL(string: "https://other.test/")!, in: tab) { decisions.values.append($0) }
        engine.admitMainFrameLoad(URL(string: "http://\(host)/")!, in: tab) { decisions.values.append($0) }
        #expect(decisions.values == [true, true])
    }
}
