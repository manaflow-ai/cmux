import CmuxNextAgentCursorVisibility
import Foundation
import Testing

/// The main-thread cost of one `AgentCursorVisibilityResolver.resolve` call, the
/// work the cursor host does for each agent input event (a streamed agent pointer
/// move included), in nanoseconds per call: p50, p95, p99 and max over every case
/// of schemas/agent-cursor-visibility/vectors.json. A measurement, not a gate: the
/// A/B of the Swift rules against the Rust call (B9) runs it alone on an exclusive
/// host with the resolver of each arm.
///
/// ```
/// CMUX_AGENT_CURSOR_VISIBILITY_BENCH=1 swift test -c release --filter AgentCursorVisibilityResolveBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_AGENT_CURSOR_VISIBILITY_BENCH"] == "1"))
struct AgentCursorVisibilityResolveBench {
    private static let rounds = 2_000

    @Test func nanosecondsPerResolve() throws {
        let cases = try AgentCursorVisibilityVectorTests.vectors().cases
        var sink = 0
        for item in cases {  // warm
            if case .visible = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
        }
        var samples: [UInt64] = []
        samples.reserveCapacity(Self.rounds * cases.count)
        for _ in 0..<Self.rounds {
            for item in cases {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot)
                samples.append(DispatchTime.now().uptimeNanoseconds - start)
                if case .visible = result { sink &+= 1 }
            }
        }
        samples.sort()
        func quantile(_ q: Double) -> UInt64 { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        print("agent-cursor-visibility bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "\(samples.count) resolves over \(cases.count) vectors: p50 \(quantile(0.5)) ns, p95 \(quantile(0.95)) ns, "
              + "p99 \(quantile(0.99)) ns, max \(samples.last ?? 0) ns (sink \(sink & 1))")
        #expect(samples.count == Self.rounds * cases.count)
    }
}
