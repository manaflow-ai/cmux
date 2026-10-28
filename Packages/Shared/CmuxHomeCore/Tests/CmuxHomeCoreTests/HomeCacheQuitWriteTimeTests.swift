import Foundation
import Testing
@testable import CmuxHomeCore

/// How long the quit's last Home cache write takes with a large Home (the forced-exit limit in
/// cmux-next's AppDelegate is at least 3 times its p99, capped at 250 ms: lead, 2026-10-24).
/// Printed as `HOME-CACHE-QUIT-WRITE` lines for the fleet log; it checks only that every write
/// reached disk.
///
/// Large Home: 300 conversations, 40 opened windows of 200 messages (about 240 characters each),
/// 40 drafts. One draft changes per write, as at quit. Cold: a new cache actor on the files a
/// previous launch wrote (it reads them first, as the first write after a launch does). Warm: the
/// same actor again.
@Suite(.serialized) struct HomeCacheQuitWriteTimeTests {
    static let author = ParticipantID("agent_chief")
    static let text = String(repeating: "a reply line with words in it, ", count: 8)

    static func largeState() -> HomeCacheState {
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
        let chief = Participant(id: author, kind: .agent, displayName: "Chief", agentClass: .chief)
        var state = HomeCacheState()
        state.me = me
        for index in 0..<300 {
            let id = ConversationID("conv_\(index)")
            state.conversations[id] = ConversationSummary(id: id, participants: [me, chief], lastSeq: 200, rev: 1,
                                                          createdAt: Date(timeIntervalSince1970: 0),
                                                          updatedAt: Date(timeIntervalSince1970: Double(index)), pinRank: nil)
            if index < 40 {
                state.windows[id] = (1...200).map { seq in
                    Message(id: MessageID("\(id.rawValue)-m\(seq)"), conversation: id, seq: Seq(seq),
                            clientMessageID: IdempotencyKey("\(id.rawValue)-k\(seq)"), author: author,
                            parts: [.text(text)], createdAt: Date(timeIntervalSince1970: Double(seq)))
                }
                state.drafts[id] = "draft \(index)"
            }
        }
        return state
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func summary(_ name: String, _ values: [Double]) -> String {
        let sorted = values.sorted()
        let p99 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.up)) - 1)]
        return String(format: "HOME-CACHE-QUIT-WRITE %@ n=%d p50=%.2f ms p99=%.2f ms max=%.2f ms",
                      name, sorted.count, sorted[sorted.count / 2], p99, sorted.last ?? 0)
    }

    @Test func aDraftChangeWriteWithALargeHome() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-quit-write-\(UUID().uuidString)/home.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var state = Self.largeState()
        let writer = UUID()
        #expect(await HomeCache(url: url).write(state, sequence: 1, writer: writer))
        let clock = ContinuousClock()
        var cold: [Double] = []
        var warm: [Double] = []
        var sequence: UInt64 = 1
        for round in 0..<30 {
            sequence += 1
            state.drafts[ConversationID("conv_0")] = "cold \(round)"
            let fresh = HomeCache(url: url)
            let started = clock.now
            #expect(await fresh.write(state, sequence: sequence, writer: writer))
            cold.append(Self.milliseconds(clock.now - started))
            sequence += 1
            state.drafts[ConversationID("conv_1")] = "warm \(round)"
            let again = clock.now
            #expect(await fresh.write(state, sequence: sequence, writer: writer))
            warm.append(Self.milliseconds(clock.now - again))
        }
        print(Self.summary("cold", cold))
        print(Self.summary("warm", warm))
    }
}
