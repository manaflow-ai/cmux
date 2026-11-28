import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// RFD 0191 step 5: the agent pane's transport hot paths with a budget on every pull request, at thousands of
/// frames. The full benches stay where they are (`AcpmuxPaneInboundScanBench`, `AgentPaneTransportBenchParse` and
/// `ChatTailJSONPathBench`; the WebView round trip in `AgentPaneTransportBench` stays env-gated). These are their
/// headless cores, sized to finish in about a second.
///
/// Each one runs at n and 10n and checks two things. An absolute budget per unit of work, set at about 4x the
/// number measured on a fleet Mac. And a flat-cost ratio: time(10n) / time(n), per unit, must stay at or under
/// `flatRatio`. A shared CI Mac's noise moves both sizes together, so the ratio fails open on a slow host. It
/// catches a path that turns quadratic (×10 per unit), which is the regression the RFD's hot paths had.
@Suite(.serialized)
struct AgentPaneTransportBudgets {
    /// time(10n) per unit over time(n) per unit. Linear is 1; quadratic is 10.
    static let flatRatio = 3.0

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The median of `runs` timings of `body`, in milliseconds.
    static func median(_ runs: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            body()
            samples.append(milliseconds(start.duration(to: ContinuousClock.now)))
        }
        return samples.sorted()[runs / 2]
    }

    static func report(_ name: String, unit: String, small: Double, large: Double, budget: Double) {
        let ratio = large / max(small, 1e-9)
        print(String(format: "PANE-BUDGET %@ small_ms_per_%@=%.4f large_ms_per_%@=%.4f ratio_10x=%.2f budget_ms=%.3f",
                     name, unit, small, unit, large, ratio, budget))
        #expect(large <= budget, "\(name): \(large) ms per \(unit) at 10n is over its \(budget) ms budget")
        #expect(ratio <= flatRatio, "\(name): cost per \(unit) grew \(ratio)x from n to 10n (flat is 1)")
    }

    // MARK: Inbound: socket receive, page-wait scan, page queue take

    /// `AcpmuxPaneInboundScanBench.pass` at 400 and 4,000 frames of 2 KB: CPU per 1,000 frames.
    @MainActor @Test func inboundPassPerThousandFrames() async {
        let small = AcpmuxPaneInboundScanBench.turn(frames: 400, bytes: 2_048)
        let large = AcpmuxPaneInboundScanBench.turn(frames: 4_000, bytes: 2_048)
        _ = await AcpmuxPaneInboundScanBench.pass(Array(small.prefix(100))) // warm up
        func perThousand(_ frames: [String]) async -> Double {
            var samples: [Double] = []
            for _ in 0..<3 { samples.append(Self.milliseconds(await AcpmuxPaneInboundScanBench.pass(frames).cpu)) }
            return samples.sorted()[1] * 1_000 / Double(frames.count)
        }
        let smallMs = await perThousand(small)
        let largeMs = await perThousand(large)
        Self.report("inbound-pass", unit: "1k_frames", small: smallMs, large: largeMs, budget: Self.inboundPerThousandBudget)
    }

    // MARK: Send path: the duplicate-key check and id swap every frame passes

    static let notification = #"{"jsonrpc":"2.0","method":"session/update","params":{"s":12,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(String(repeating: "x", count: 200))"}}}}"#

    /// `AcpmuxRequestIds.toPage` plus `AcpmuxJSONKeys.refuses` over 1,000 and 10,000 notifications.
    @Test func notificationPathPerThousandFrames() {
        func perThousand(_ count: Int) -> Double {
            let ids = AcpmuxRequestIds()
            let frames = (0..<count).map { Self.notification.replacingOccurrences(of: #""s":12"#, with: #""s":\#($0)"#) }
            return Self.median(3) {
                for frame in frames {
                    precondition(!AcpmuxJSONKeys.refuses(Array(frame.utf8)))
                    guard case .page = ids.toPage(frame) else { preconditionFailure("not forwarded") }
                }
            } * 1_000 / Double(count)
        }
        _ = perThousand(200) // warm up
        let small = perThousand(1_000)
        let large = perThousand(10_000)
        Self.report("notification-path", unit: "1k_frames", small: small, large: large, budget: Self.notificationPerThousandBudget)
    }

    /// The duplicate-key check on one `_acpmux/events` page of 100 and 1,000 events (100 KB and 1 MB): per MB.
    @Test func keyCheckPerMegabyte() {
        func perMegabyte(_ count: Int) -> Double {
            let bytes = Array(AgentPaneTransportBenchParse.eventsPage(count: count, textBytes: 1_000).utf8)
            return Self.median(5) { precondition(!AcpmuxJSONKeys.refuses(bytes)) } * Double(1 << 20) / Double(bytes.count)
        }
        _ = perMegabyte(50) // warm up
        let small = perMegabyte(100)
        let large = perMegabyte(1_000)
        Self.report("key-check", unit: "MB", small: small, large: large, budget: Self.keyCheckPerMegabyteBudget)
    }

    // MARK: Chat tail: write and read through the page host

    /// A tail of `count` records of the bound tail's record size.
    static func tail(_ count: Int) -> JSONValue {
        let text = String(repeating: "x", count: AgentPaneTailCache.bytes / AgentPaneTailCache.events - 160)
        let events: [JSONValue] = (1...count).map {
            .object(["seq": .number(Double($0)), "kind": .string("agent_message"),
                     "msg": .object(["text": .string(text), "blocks": .array([.object(["type": .string("text"), "n": .number(Double($0))])])])])
        }
        return .object(["events": .array(events), "historyExhausted": .bool(false), "queue": .array([]),
                        "configSeq": .number(0), "usageFromSeq": .number(0)])
    }

    /// `chat.tail` then `chat.tail.get` through `AgentPageProvider` at 40 and 400 records (the store's bound):
    /// milliseconds per 100 records, no load.
    @MainActor @Test func chatTailPerHundredRecords() async throws {
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
        defer { AgentPaneTailCache.shared.clear(); AgentPaneTailCache.shared.resume() }
        let provider = AgentPageProvider { _ in nil }
        let context = PageCallContext(page: PageDescriptor.agent.id)
        let read: JSONValue = .object(["sessionId": .string("budget")])
        func perHundred(_ count: Int) async throws -> Double {
            let tail = Self.tail(count)
            #expect(AgentPaneTailCache.holds(tail))
            let write: JSONValue = .object(["sessionId": .string("budget"), "tail": tail])
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                _ = try await provider.call(AgentPageOps.namespace + "chat.tail", params: write, context: context)
                let got = try await provider.call(AgentPageOps.namespace + "chat.tail.get", params: read, context: context)
                samples.append(Self.milliseconds(start.duration(to: ContinuousClock.now)))
                #expect(got == tail)
            }
            return samples.sorted()[2] * 100 / Double(count)
        }
        _ = try await perHundred(20) // warm up
        let small = try await perHundred(AgentPaneTailCache.events / 10)
        let large = try await perHundred(AgentPaneTailCache.events)
        Self.report("chat-tail", unit: "100_records", small: small, large: large, budget: Self.chatTailPerHundredBudget)
    }

    /// Budgets at 10n: about 4x the fleet Mac's number (the PR that added this file lists them).
    static let inboundPerThousandBudget = 400.0
    static let notificationPerThousandBudget = 400.0
    static let keyCheckPerMegabyteBudget = 400.0
    static let chatTailPerHundredBudget = 400.0
}
