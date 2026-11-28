import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The stress harness of plans/cmux-next/home-chat-pipeline-DESIGN.md section 4.3: 100 agents
/// stream fast into their own conversations while the Chief's reply streams in the open Home view
/// and the user sends mid-stream. Records the main-thread time of every pass, p50/p95/p99/max, as
/// `HOME_STRESS` lines in the log (and JSON in `$HOME_STRESS_OUT`). Run on the Mac minis.
@MainActor @Suite(.serialized) struct HomeStreamStressTests {
    struct Timings: Codable {
        var samples: [Double] = [] // milliseconds
        mutating func add(_ d: Duration) { samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        func percentile(_ p: Double) -> Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        var line: String {
            String(format: "n=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms", samples.count,
                   percentile(0.5), percentile(0.95), percentile(0.99), samples.max() ?? 0)
        }
    }

    @Test func hundredAgentsStreamWhileTheChiefReplies() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        let clock = ContinuousClock()
        var other = Timings(), chiefChunk = Timings(), sendFrame = Timings()
        let agents = (0..<100).map { ConversationID("conv_stress_\($0)") }
        let t = HomeChatRig.tag
        var chiefSeq: UInt64 = 0
        var agentSeq = [UInt64](repeating: 0, count: agents.count)
        rig.delta("stress_chief", seq: 0, "\(t)stress reply:")
        rig.frame()
        var sends = 0
        for round in 0..<40 {
            for (i, conversation) in agents.enumerated() {
                rig.store.handle(.live(.delta(HomeLiveDelta(
                    conversation: conversation, author: ParticipantID("agent_stress_\(i)"), run: "run_\(i)", step: "talk",
                    isTalk: true, seq: agentSeq[i], text: agentSeq[i] == 0 ? "agent \(i):" : " w\(round)", isFinal: false))))
                agentSeq[i] += 1
                // Other conversations' traffic: the open view's observed pass.
                let start = clock.now
                rig.view.projection.observedPass()
                other.add(clock.now - start)
                if i % 10 == 9 {
                    chiefSeq += 1
                    rig.delta("stress_chief", seq: chiefSeq, " word\(round)_\(i)")
                    let s = clock.now
                    rig.frame()
                    chiefChunk.add(clock.now - s)
                }
            }
            if round % 8 == 7 {
                // A send mid-stream: the frame of the Return.
                sends += 1
                rig.view.controller.dispatch(.setDraft("\(t)stress send \(sends)"))
                let s = clock.now
                _ = rig.view.projection.send()
                rig.frame()
                sendFrame.add(clock.now - s)
                let sent = "\(t)stress send \(sends)"
                await HomeChatRig.until { [rig] in rig.store.transcript(for: HomeChatRig.conversation).contains { $0.plainText == sent } }
            }
        }
        await HomeChatRig.until { [rig] in
            !rig.store.transcript(for: HomeChatRig.conversation).contains { $0.plainText.hasPrefix("\(t)stress send") && $0.seq == nil }
        }
        rig.frame()
        let report = ["other_conversation_pass": other, "chief_chunk_frame": chiefChunk, "send_frame": sendFrame]
        for (name, timings) in report.sorted(by: { $0.key < $1.key }) { print("HOME_STRESS \(name) \(timings.line)") }
        if let out = ProcessInfo.processInfo.environment["HOME_STRESS_OUT"] {
            let data = try JSONEncoder().encode(report.mapValues { ["p50": $0.percentile(0.5), "p95": $0.percentile(0.95),
                                                                    "p99": $0.percentile(0.99), "max": $0.samples.max() ?? 0] })
            try data.write(to: URL(fileURLWithPath: out))
        }
        // The reply is one bubble and the sends are above it, in the store's order.
        let shown = rig.bubbles()
        #expect(shown.filter { $0.hasPrefix("\(t)stress reply:") }.count == 1, "the reply shows in one bubble")
        #expect(Array(shown.dropLast()) == rig.storeItems(), "the view shows the store's order")
        // One display frame at 60 Hz for the median Chief chunk; the numbers above are the record.
        #expect(chiefChunk.percentile(0.5) < 16.7, "median Chief chunk frame \(chiefChunk.line)")
    }
}
