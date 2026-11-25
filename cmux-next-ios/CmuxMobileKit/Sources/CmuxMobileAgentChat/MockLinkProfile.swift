// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import CmuxMobileModel
import Foundation

/// A demo chat whose history comes `delay` late, as from a slow Mac: it says it loads history
/// (``AgentSessionSource/loadsHistory``) and says when it caught up.
@MainActor
public final class DelayedHistorySource: AgentSessionSource {
    let inner: MockAgentSession
    let delay: Duration

    public init(inner: MockAgentSession, delay: Duration) {
        self.inner = inner
        self.delay = delay
    }

    public var summary: AgentSessionSummary { inner.summary }
    public var loadsHistory: Bool { true }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let inner = inner, delay = delay
        Task { @MainActor in
            // Demo only: stands in for a Mac that answers late.
            try? await Task.sleep(for: delay)
            var first = true
            for await event in inner.events() {
                continuation.yield(event)
                if first {
                    first = false
                    continuation.yield(.historyLoading(false))
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func send(_ intent: AgentClientIntent) { inner.send(intent) }
}

/// `CMUX_MOBILE_MOCK_LINK` (mock data only): the mock Mac's link, so a chat's history arrives as
/// late as over that link (`LoadShiftsUITests`' wifi, lte and lossy-3 rows). `wifi`, `lte`,
/// `lossy-3` (cmux-fault's link profiles: lte 70 ms RTT and 0.5 % loss, lossy-3 70 ms RTT,
/// 0-300 ms jitter and 3 % loss; wifi 20 ms RTT), or `rtt_ms,jitter_ms,loss_percent`.
public struct MockLinkProfile: Sendable, Equatable {
    public var rttMs: Double
    public var jitterMs: Double
    public var lossPercent: Double

    public static var current: MockLinkProfile? {
        ProcessInfo.processInfo.environment["CMUX_MOBILE_MOCK_LINK"].flatMap(MockLinkProfile.init(_:))
    }

    public init?(_ text: String) {
        switch text {
        case "wifi": (rttMs, jitterMs, lossPercent) = (20, 0, 0)
        case "lte": (rttMs, jitterMs, lossPercent) = (70, 0, 0.5)
        case "lossy-3": (rttMs, jitterMs, lossPercent) = (70, 300, 3)
        default:
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            (rttMs, jitterMs, lossPercent) = (parts[0], parts[1], parts[2])
        }
    }

    /// A history read's time over this link: a request and its answer (2 RTT, the second with
    /// jitter), and a retransmit (at least 200 ms, twice the RTT) for each of its 8 packets lost.
    public func historyDelay<G: RandomNumberGenerator>(using random: inout G) -> Duration {
        var ms = 2 * rttMs + (jitterMs > 0 ? Double.random(in: 0...jitterMs, using: &random) : 0)
        for _ in 0..<8 where Double.random(in: 0..<100, using: &random) < lossPercent { ms += max(200, 2 * rttMs) }
        return .milliseconds(Int(ms.rounded()))
    }
}
#endif
