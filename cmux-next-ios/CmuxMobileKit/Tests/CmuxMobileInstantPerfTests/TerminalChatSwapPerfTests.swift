#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileLive
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

// h. terminal_chat_swap   Toggle Terminal and Chat on the phone (Leo, 2026-11-12: "instant both ways,
//                          mid-turn, no reload"; target p95 under 100 ms). A tap on the other face of
//                          a terminal running Claude Code or Codex: Rust's `terminal_chat_swap`, the
//                          face flag, and the parked pair (`TerminalChatPair`, the terminal and the
//                          chat transcript both built) laid out and committed with the other face
//                          visible, at 390 x 800 pt. Each way is timed apart, small vs god chat; the
//                          note has each way's p50 and p95. The chat's store and turns must be the
//                          same objects after every swap: nothing reloads, nothing is lost or doubled.

@MainActor
extension InstantPerfTests {
    /// The page as the tab draws it: the terminal face (a stand-in grid: libghostty's surface is
    /// the terminal's own cost, the same with or without the chat) under the chat transcript.
    struct SwapHost: View {
        let showsChat: Bool
        let store: AgentChatStore
        let surface: AgentChatSurface

        var body: some View {
            TerminalChatPair(showsChat: showsChat) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<48, id: \.self) { row in
                        Text("\(row) $ claude  ▌ working on the relay, 24 tests pass").font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
            } chat: {
                AgentChatTranscript(store: store, surface: surface, topInset: 60)
            }
            .overlay(alignment: .topTrailing) {
                TerminalChatToggleControl(showsChat: showsChat) { _ in }
            }
        }
    }

    /// One chat's swaps: `runs` each way after a warm-up, in ms (to chat, to terminal).
    static func swaps(_ log: AgentChatLog, runs: Int) async throws -> (toChat: [Double], toTerminal: [Double]) {
        let fake = InstantPerfAcpmux(log)
        let hub = try await boundHub(fake.link())
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        let newest = try #require(log.lastTurn(before: log.count))
        try #require(await waitUntil { shows(store, newest) }, "the chat never showed \(newest)")
        let surface = AgentChatSurface()
        let hosting = UIHostingController(rootView: SwapHost(showsChat: true, store: store, surface: surface))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        hosting.view.layoutIfNeeded()
        // The chat's rows are laid out over the first frames, as on a page that just opened.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(16)) // test: a display frame for the first layout
            hosting.view.layoutIfNeeded()
        }
        let turns = store.turns.map(\.id)
        let facts = TerminalChatFacts(terminal: true, chat: false, agent: "claude", session: "h-1", running: false, chatRefused: false)
        var shown = TabFace.chat
        func swap(to face: TabFace) -> Duration {
            ContinuousClock().measure {
                guard case .show(let next) = terminalChatSwap(facts: facts, shown: shown, to: face) else {
                    Issue.record("the swap to \(face) was not a show")
                    return
                }
                shown = next
                hosting.rootView = SwapHost(showsChat: next == .chat, store: store, surface: surface)
                hosting.view.setNeedsLayout()
                hosting.view.layoutIfNeeded()
                CATransaction.flush()
            }
        }
        var toChat: [Double] = []
        var toTerminal: [Double] = []
        for index in 0...runs {
            let terminal = swap(to: .terminal)
            try await Task.sleep(for: .milliseconds(16)) // test: one frame on each face, as a person's taps are
            let chat = swap(to: .chat)
            try await Task.sleep(for: .milliseconds(16)) // test: as above
            guard index > 0 else { continue } // the warm-up
            toTerminal.append(InstantPerfReport.ms(terminal))
            toChat.append(InstantPerfReport.ms(chat))
        }
        // The same store, the same turns: the chat face never reloaded, lost or doubled a message.
        #expect(store.turns.map(\.id) == turns, "the chat's turns changed across swaps")
        #expect(Set(turns).count == turns.count, "a turn shows twice")
        withExtendedLifetime((hub, fake)) {}
        return (toChat, toTerminal)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))]
    }

    @Test("terminal_chat_swap")
    func terminalChatSwapBench() async throws {
        let runs = max(InstantPerfReport.defaultRuns * 8, 40)
        let small = try await Self.swaps(AgentChatFixture.small, runs: runs)
        let god = try await Self.swaps(AgentChatFixture.god, runs: runs)
        let ways: [(String, [Double], [Double])] = [("to_chat", small.toChat, god.toChat), ("to_terminal", small.toTerminal, god.toTerminal)]
        for (way, smallRuns, godRuns) in ways {
            let line = String(format: "p50/p95 small %.2f/%.2f ms, god %.2f/%.2f ms over %d swaps each; Leo's target p95 < 100 ms",
                              Self.percentile(smallRuns, 0.5), Self.percentile(smallRuns, 0.95),
                              Self.percentile(godRuns, 0.5), Self.percentile(godRuns, 0.95), runs)
            print("TERMINALCHATSWAP \(way) \(line)")
            // 33 ms target: the 3x budget is Leo's 100 ms.
            InstantPerfReport.record("terminal_chat_swap_\(way)", target: 33, small: smallRuns, god: godRuns, note: line)
            #expect(Self.percentile(smallRuns, 0.95) < 100, "terminal_chat_swap \(way): small p95 over 100 ms (\(line))")
            #expect(Self.percentile(godRuns, 0.95) < 100, "terminal_chat_swap \(way): god p95 over 100 ms (\(line))")
        }
    }
}
#endif
