import CmuxNextAgentCursorVisibility
import Foundation
import Testing

/// The main-thread cost of one `AgentCursorVisibilityResolver.resolve` call, the
/// work the cursor host does for each agent input event (a streamed agent pointer
/// move included) and per frame of pane motion while a target is tracked, in
/// nanoseconds per call: p50, p95, p99 and max over samples of a batch of
/// resolves that rotate through schemas/agent-cursor-visibility/vectors.json. A measurement, not a gate: the
/// A/B of the Swift rules against the Rust call (B9) runs it alone on an exclusive
/// host with the resolver of each arm.
///
/// ```
/// CMUX_AGENT_CURSOR_VISIBILITY_BENCH=1 swift test -c release --filter AgentCursorVisibilityResolveBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_AGENT_CURSOR_VISIBILITY_BENCH"] == "1"))
struct AgentCursorVisibilityResolveBench {
    /// Resolves timed together per sample: one resolve is a few timer ticks
    /// (about 42 ns each on Apple silicon), so a sample of one cannot tell two
    /// fast resolvers apart; a sample is ns per call over the batch.
    private static let batch = 1_000
    private static let samples = 400

    @Test func nanosecondsPerResolve() throws {
        let cases = try AgentCursorVisibilityVectorTests.vectors().cases
        var sink = 0
        for item in cases {  // warm
            if case .visible = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
        }
        var perCall: [Double] = []
        perCall.reserveCapacity(Self.samples)
        var next = 0
        for _ in 0..<Self.samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<Self.batch {
                // Every vector in turn, so a batch covers every rule path.
                let item = cases[next]
                next = next + 1 == cases.count ? 0 : next + 1
                if case .visible = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
            }
            perCall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(Self.batch))
        }
        perCall.sort()
        func quantile(_ q: Double) -> Double { perCall[min(perCall.count - 1, Int(Double(perCall.count) * q))] }
        func ns(_ value: Double) -> String { String(format: "%.1f", value) }
        print("agent-cursor-visibility bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "\(Self.samples) samples of \(Self.batch) resolves over \(cases.count) vectors, ns per call: "
              + "p50 \(ns(quantile(0.5))) ns, p95 \(ns(quantile(0.95))) ns, p99 \(ns(quantile(0.99))) ns, "
              + "max \(ns(perCall.last ?? 0)) ns (sink \(sink & 1))")
        #expect(perCall.count == Self.samples)
    }
}
