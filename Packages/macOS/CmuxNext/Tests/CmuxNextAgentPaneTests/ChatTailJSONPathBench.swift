import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Duress before/after for cmuxterm-hq#19028: a tail at the store's bounds (``AgentPaneTailCache/events``
/// records, near ``AgentPaneTailCache/bytes``) written and read through the shared page host while
/// every core is kept busy, timed on the main actor. "before" is the Foundation path the page host
/// took (params and answer walked into Foundation and back), still the pane bridge's own edge;
/// "after" is the page host now.
/// Run it with `CMUX_CHAT_TAIL_BENCH=1`; the bench tier (suite timeout 901, as `AgentPageProviderBridgeGapBench`) runs it too.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_CHAT_TAIL_BENCH"] == "1"
    || ProcessInfo.processInfo.environment["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] == "901"))
@MainActor
struct ChatTailJSONPathBench {
    private static let rounds = 40

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    /// A tail of the store's most records, each with a long message, under its byte bound.
    private static func boundTail() -> JSONValue {
        let text = String(repeating: "x", count: AgentPaneTailCache.bytes / AgentPaneTailCache.events - 160)
        let events: [JSONValue] = (1...AgentPaneTailCache.events).map {
            .object(["seq": .number(Double($0)), "kind": .string("agent_message"),
                     "msg": .object(["text": .string(text), "blocks": .array([.object(["type": .string("text"), "n": .number(Double($0))])])])])
        }
        return .object(["events": .array(events), "historyExhausted": .bool(false), "queue": .array([]),
                        "configSeq": .number(0), "usageFromSeq": .number(0)])
    }

    @Test func boundTailUnderLoad() async throws {
        AgentPaneTailCache.shared.clear()
        AgentPaneTailCache.shared.resume()
        defer { AgentPaneTailCache.shared.clear(); AgentPaneTailCache.shared.resume() }
        let tail = Self.boundTail()
        #expect(AgentPaneTailCache.holds(tail))
        let write: JSONValue = .object(["sessionId": .string("bench"), "tail": tail])
        let read: JSONValue = .object(["sessionId": .string("bench")])
        let provider = AgentPageProvider { _ in nil }
        let context = PageCallContext(page: PageDescriptor.agent.id)

        // Duress: every core busy for the whole measurement.
        let stop = ManagedAtomicFlag()
        let load = (0..<ProcessInfo.processInfo.activeProcessorCount).map { _ in
            Thread { var x: UInt64 = 1; while !stop.isSet { x = x &* 6364136223846793005 &+ 1 }; _ = x }
        }
        load.forEach { $0.start() }
        defer { stop.set() }

        var before = ContinuousClock.Duration.zero
        var after = ContinuousClock.Duration.zero
        for _ in 0..<Self.rounds {
            let start = ContinuousClock.now
            _ = try AgentPageProvider.value(of: AgentPaneTailCache.reply(to: "chat.tail", params: write.foundationObject as? [String: Any]))
            let old = try AgentPageProvider.value(of: AgentPaneTailCache.reply(to: "chat.tail.get", params: read.foundationObject as? [String: Any]))
            before += start.duration(to: ContinuousClock.now)
            #expect(old == tail)

            let began = ContinuousClock.now
            _ = try await provider.call(AgentPageOps.namespace + "chat.tail", params: write, context: context)
            let new = try await provider.call(AgentPageOps.namespace + "chat.tail.get", params: read, context: context)
            after += began.duration(to: ContinuousClock.now)
            #expect(new == tail)
        }
        let beforeMs = Self.milliseconds(before) / Double(Self.rounds)
        let afterMs = Self.milliseconds(after) / Double(Self.rounds)
        print("CHAT-TAIL-BENCH events=\(AgentPaneTailCache.events) cores_loaded=\(load.count) rounds=\(Self.rounds) before_main_ms=\(String(format: "%.3f", beforeMs)) after_main_ms=\(String(format: "%.3f", afterMs))")
        #expect(afterMs < beforeMs)
    }
}

/// A stop flag the load threads read.
private nonisolated final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
