import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-11-05: "if you delete a tab and create like and delete in the middle of it, there's like this
/// weird shuffle reordering going on ... if something is optimistic, then we should be able to follow along
/// with the optimistic stuff." Cmd-T puts the new tab right after the current one; a close while it is made
/// (its anchor, or another tab) must not move it: from the press on, every frame shows the tabs that stay in
/// one order, with the new tab where it first showed, through the stand-in, the daemon's tab and its move.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabCloseInterleaveDiagTests {
    /// Which of the three tabs `a b c` (b selected, so the new tab goes between b and c) is closed while
    /// the new tab is made: its anchor, its right neighbor, its left one.
    enum Closed: String, CaseIterable, Sendable { case anchor, right, left }

    /// The strip as letters, one entry per change: `a`, `b`, `c` for the three tabs, `N` for the new one
    /// (stand-in or daemon's); the pane's other tabs (its first terminal) are left out.
    @MainActor final class StripFrames {
        let names: [String: String]
        let earlier: Set<String>
        private(set) var frames: [[String]] = []

        init(names: [String: String], earlier: Set<String>) {
            self.names = names
            self.earlier = earlier
        }

        func sample(_ pane: PaneController) {
            let shown: [String] = pane.orderedIDs.compactMap { id in
                if let name = names[id.rawValue] { return name }
                return earlier.contains(id.rawValue) ? nil : "N"
            }
            if frames.last != shown {
                frames.append(shown)
                let store = pane.pane.tabs.map { names[$0.id] ?? (earlier.contains($0.id) ? "x" : ($0.id.hasPrefix("pending_tab_") ? "p" : "d")) }
                print("DIAGFRAME ids=\(names.map { "\($0.key.suffix(6))=\($0.value)" }.sorted()) strip=\(shown.joined()) store=\(store.joined())")
            }
        }
    }

    /// The order the strip settles at: the new tab stays where it showed (right after b).
    static func settled(_ closed: Closed) -> [String] {
        switch closed {
        case .anchor: ["a", "N", "c"]
        case .right: ["a", "b", "N"]
        case .left: ["b", "N", "c"]
        }
    }

    enum When: String, CaseIterable, Sendable { case sameTurn }

    @Test(arguments: Closed.allCases, When.allCases)
    func diag(closed: Closed, when: When) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-close-interleave")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            var ids: [String] = []
            for _ in 0..<3 {
                let surface = try await connection.newTab(in: pane.pane.handle).surface
                try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
                let tab = try #require(store.tab(surface: surface))
                ids.append(tab.id)
            }
            let made = Set(ids)
            try await PasswordManagerRouteTests.until({ made.isSubset(of: Set(pane.orderedIDs.map(\.rawValue))) },
                                                      report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
            pane.select(TabID(ids[1]))
            let victim: String
            switch closed {
            case .anchor: victim = ids[1]
            case .right: victim = ids[2]
            case .left: victim = ids[0]
            }
            let names: [String: String] = [ids[0]: "a", ids[1]: "b", ids[2]: "c"]
            let recorder = StripFrames(names: names, earlier: Set(pane.orderedIDs.map(\.rawValue)))

            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            recorder.sample(pane)
            print("DIAGCASE closed=\(closed) when=\(when)")
            let known = Set(pane.pane.tabs.map(\.id))
            switch when {
            case .sameTurn: break
            case .ms30: try await Task.sleep(for: .milliseconds(30))
            case .ms150: try await Task.sleep(for: .milliseconds(150))
            case .daemonTab:
                let end = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < end, !pane.pane.tabs.contains(where: { !known.contains($0.id) && !$0.id.hasPrefix("pending_tab_") }) {
                    recorder.sample(pane)
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            recorder.sample(pane)
            print("DIAGCLOSE")
            pane.handle(.close(TabID(victim), source: .mouse))
            recorder.sample(pane)
            // Past the placement window (NewTabSuccession.orderLimit) and the new tab's move.
            let settle = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < settle {
                recorder.sample(pane)
                try await Task.sleep(for: .milliseconds(5))
            }

            let want = Self.settled(closed)
            let victimName = names[victim] ?? "?"
            let frames = recorder.frames
            let seen = frames.map { $0.joined() }
            let afterClose = frames.drop { $0.contains(victimName) || !$0.contains("N") }
            print("DIAGRESULT closed=\(closed) when=\(when) ok=\(afterClose.allSatisfy { $0 == want } && frames.last == want) frames=\(seen)")
            #expect(afterClose.allSatisfy { $0 == want }, "the strip reordered: \(seen)")
            #expect(frames.last == want, "settled at \(frames.last?.joined() ?? "-"), want \(want.joined()); \(seen)")
        }
    }
}
