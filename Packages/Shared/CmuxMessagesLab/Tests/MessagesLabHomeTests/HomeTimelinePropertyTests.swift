import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Random interleavings of everything that moves the Home transcript (plans/cmux-next/
/// home-chat-pipeline-DESIGN.md section 4.2): sends, held and released acks, live deltas (with
/// repeats), runs ending, replies posted, someone else's messages, a reconnect snapshot replay,
/// older pages and resizes. After every step the view shows exactly the order the rules give,
/// computed here on its own (the oracle), and every reply shows in one bubble. A failing seed
/// prints its steps.
@MainActor @Suite(.serialized) struct HomeTimelinePropertyTests {
    /// A small deterministic generator (SplitMix64), so a seed replays.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    /// The oracle's running reply: its text so far and whether it ended `done` (waiting for its reply).
    struct Run {
        var id: String
        var seq: UInt64
        var text: String
        var done = false
    }

    /// Nonisolated: `@Test(arguments:)` reads it outside the main actor.
    nonisolated static let seeds: [UInt64] = Array(1...24)

    @Test(arguments: seeds)
    func everyInterleavingShowsTheOwnersOrder(seed: UInt64) async throws {
        let rig = try await HomeChatRig(history: 30)
        defer { rig.stop() }
        var rng = Rng(state: seed)
        var runs: [Run] = [] // begin order
        var nextRun = 1, nextSend = 1, nextOther = 1, nextWord = 1
        var holding = false
        var log: [String] = []
        let t = HomeChatRig.tag

        func expected() -> [String] {
            rig.storeItems() + runs.filter { !$0.text.isEmpty }.map(\.text)
        }

        for step in 0..<90 {
            let roll = rng.int(100)
            switch roll {
            case 0..<14: // send
                let text = "\(t)m\(nextSend)"
                nextSend += 1
                if await rig.send(text) == nil { log.append("send \(text)") }
            case 14..<20: // hold or release acks
                if holding {
                    await rig.releaseSends()
                    log.append("release sends")
                } else {
                    await rig.holdSends()
                    log.append("hold sends")
                }
                holding.toggle()
            case 20..<30: // a turn begins
                let id = "r\(seed)_\(nextRun)"
                nextRun += 1
                let text = "\(t)\(id):"
                rig.delta(id, seq: 0, text)
                runs.append(Run(id: id, seq: 0, text: text))
                log.append("begin \(id)")
            case 30..<58: // a delta, sometimes a repeat of the last one
                guard let i = runs.indices.filter({ !runs[$0].done }).pick(using: &rng) else { continue }
                if rng.chance(0.15), runs[i].seq > 0 {
                    rig.delta(runs[i].id, seq: runs[i].seq, " repeat-ignored")
                    log.append("repeat \(runs[i].id)#\(runs[i].seq)")
                } else {
                    let word = " w\(nextWord)"
                    nextWord += 1
                    runs[i].seq += 1
                    runs[i].text += word
                    rig.delta(runs[i].id, seq: runs[i].seq, word)
                    log.append("delta \(runs[i].id)#\(runs[i].seq)")
                }
            case 58..<64: // a run ends done: its text waits for its reply
                guard let i = runs.indices.filter({ !runs[$0].done }).pick(using: &rng) else { continue }
                rig.run(runs[i].id, "done")
                runs[i].done = true
                log.append("done \(runs[i].id)")
            case 64..<76: // a reply is posted (its run's whole text, its run id as the key)
                guard let i = Array(runs.indices).pick(using: &rng) else { continue }
                let run = runs.remove(at: i)
                _ = await rig.post(run.text, key: IdempotencyKey(run.id))
                // The Chief's message ends every run of it that waits for a reply.
                runs.removeAll { $0.done }
                log.append("post \(run.id)")
            case 76..<84: // someone else's message (the Chief from the CLI)
                let text = "\(t)o\(nextOther)"
                nextOther += 1
                _ = await rig.post(text, key: .make())
                runs.removeAll { $0.done }
                log.append("other \(text)")
            case 84..<89: // a reconnect replays the owner's snapshot of the running runs
                let steps = runs.filter { !$0.done }.map {
                    HomeLiveRunSnapshot(author: rig.chief, run: $0.id,
                                        steps: [.init(step: "talk", isTalk: true, seq: $0.seq, text: $0.text)], activity: nil)
                }
                rig.store.handle(.live(.snapshot(conversation: HomeChatRig.conversation, runs: steps)))
                log.append("snapshot \(steps.count)")
            case 89..<94: // an older page
                await rig.store.loadOlder(HomeChatRig.conversation)
                log.append("older")
            default: // a resize
                let width = CGFloat(360 + rng.int(840))
                rig.resize(width: width)
                log.append("resize \(Int(width))")
            }
            rig.frame()
            let want = expected(), shown = rig.bubbles()
            if shown != want {
                Issue.record("seed \(seed) step \(step): view \(shown) != rules \(want)\nsteps: \(log.joined(separator: "; "))")
                return
            }
            for run in runs where !run.text.isEmpty {
                let holding = shown.filter { $0.hasPrefix("\(t)\(run.id):") }
                if holding.count != 1 {
                    Issue.record("seed \(seed) step \(step): \(run.id) shows in \(holding.count) bubbles\nsteps: \(log.joined(separator: "; "))")
                    return
                }
            }
        }
        if holding { await rig.releaseSends() }
        rig.frame()
        #expect(rig.bubbles() == expected(), "seed \(seed): the final view")
    }
}

extension Array {
    /// A random element from a seeded generator.
    fileprivate func pick(using rng: inout HomeTimelinePropertyTests.Rng) -> Element? {
        isEmpty ? nil : self[rng.int(count)]
    }
}
