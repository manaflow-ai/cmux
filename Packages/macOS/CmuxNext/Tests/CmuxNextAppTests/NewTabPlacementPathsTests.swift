import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-11-07 (ask-89664a51ba): "if you click the plus button, then it opens up at the rightmost side because, like,
/// that's where the plus button is", and "you make a new tab with the hotkeys, it opens up, like, subsequently", with no
/// "random race condition edge case where ... there's, like, unexpected openings". The +, its menu's New Terminal Tab, Cmd-T
/// and Ctrl-` (New Terminal Tab's key), pressed alone or in a burst in one turn, in a wide or an overflowing strip: from the
/// press on, every frame of the strip is one of the orders the presses make one by one (each + at the end, each hotkey right
/// after the tab current then), and the strip settles at the last one.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabPlacementPathsTests {
    /// What the person does: a + click, a row of the +'s menu (New Terminal Tab), Cmd-T, New Terminal Tab's key, or a click
    /// on the first new tab's close button before the daemon made it.
    nonisolated enum Press: String, Sendable { case plus, plusMenu, cmdT, ctrlBacktick, closeFirst }

    nonisolated struct Scenario: Sendable, CustomTestStringConvertible {
        let presses: [Press]
        /// A narrow window whose strip overflows (eight more tabs left of `a b c`).
        var narrow = false
        var testDescription: String { presses.map(\.rawValue).joined(separator: "+") + (narrow ? " (narrow)" : "") }
    }

    nonisolated static let scenarios: [Scenario] = [
        Scenario(presses: [.plus]), Scenario(presses: [.plusMenu]), Scenario(presses: [.cmdT]), Scenario(presses: [.ctrlBacktick]),
        Scenario(presses: [.cmdT, .cmdT]), Scenario(presses: [.cmdT, .plus]), Scenario(presses: [.plus, .cmdT]),
        Scenario(presses: [.ctrlBacktick, .cmdT]), Scenario(presses: [.cmdT, .cmdT], narrow: true), Scenario(presses: [.cmdT, .plus], narrow: true),
        Scenario(presses: [.cmdT, .cmdT, .closeFirst]),
    ]

    /// The orders the presses make one by one from `a b c` with `b` current: a + (or its menu) appends, a hotkey goes right
    /// after the current tab; each new tab (named by its press, `1`, `2`) is current after it.
    static func states(_ presses: [Press]) -> [[String]] {
        var tabs = ["a", "b", "c"], current = "b", states = [tabs]
        for (index, press) in presses.enumerated() {
            let name = "\(index + 1)"
            switch press {
            case .plus, .plusMenu: tabs.append(name)
            case .cmdT, .ctrlBacktick: tabs.insert(name, at: (tabs.firstIndex(of: current) ?? tabs.count - 1) + 1)
            case .closeFirst: tabs.removeAll { $0 == "1" }
            }
            current = name
            states.append(tabs)
        }
        return states
    }

    /// The strip as names, one entry per change. A new tab is named by the press that made it: its stand-in when the press
    /// shows it, then the daemon's tab the store says replaced that stand-in.
    @MainActor final class Frames {
        var names: [String: String]
        let earlier: Set<String>
        private(set) var frames: [[String]] = []

        init(names: [String: String], earlier: Set<String>) {
            self.names = names
            self.earlier = earlier
        }

        /// Names the tabs `pane` shows that are new since the last call after `press` (1-based).
        func nameNew(after press: Int, in pane: PaneController) {
            for id in pane.orderedIDs.map(\.rawValue) where names[id] == nil && !earlier.contains(id) { names[id] = "\(press)" }
        }

        func sample(_ pane: PaneController) {
            let creations = pane.daemon.store.creations
            let shown: [String] = pane.orderedIDs.compactMap { id in
                if let name = names[id.rawValue] { return name }
                if earlier.contains(id.rawValue) { return nil }
                // The daemon's tab that a named stand-in became.
                if let standIn = names.first(where: { creations.replacement(ofStandIn: $0.key, in: pane.pane)?.id == id.rawValue }) {
                    names[id.rawValue] = standIn.value
                    return standIn.value
                }
                return "?"
            }
            if frames.last != shown { frames.append(shown) }
        }
    }

    @Test(arguments: scenarios)
    func everyFrameShowsTheTabsWhereThePressesPutThem(scenario: Scenario) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-newtab-placement")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            if scenario.narrow { window.window?.setFrame(NSRect(x: 100, y: 100, width: 420, height: 500), display: true) }
            var ids: [String] = []
            for _ in 0..<(scenario.narrow ? 11 : 3) {
                let surface = try await connection.newTab(in: pane.pane.handle).surface
                try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
                ids.append(try #require(store.tab(surface: surface)).id)
            }
            let made = Set(ids)
            try await PasswordManagerRouteTests.until({ made.isSubset(of: Set(pane.orderedIDs.map(\.rawValue))) },
                                                      report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
            let named = Array(ids.suffix(3))
            pane.select(TabID(named[1]))
            try #require(pane.stripModel.selectedID?.rawValue == named[1])
            let frames = Frames(names: [named[0]: "a", named[1]: "b", named[2]: "c"],
                                earlier: Set(pane.orderedIDs.map(\.rawValue)).subtracting(named))
            frames.sample(pane)

            // The presses, in one turn: as fast as a person can press, faster than any daemon answer.
            for (index, press) in scenario.presses.enumerated() {
                switch press {
                case .plus:
                    pane.handle(.newTab(after: nil))
                case .plusMenu:
                    #expect(services.registry.perform("newSurface", invocation: ActionInvocation(
                        target: ActionTargetRef(kind: .pane, id: pane.paneKey), origin: .user).onMachine(pane.daemon.machineID)))
                case .cmdT:
                    #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
                case .ctrlBacktick:
                    #expect(services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)))
                case .closeFirst:
                    let first = try #require(frames.names.first { $0.value == "1" }?.key)
                    pane.handle(.close(TabID(first), source: .mouse))
                }
                frames.nameNew(after: index + 1, in: pane)
                frames.sample(pane)
            }
            // Past the placement window (NewTabSuccession.orderLimit) and the new tabs' moves.
            let settle = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < settle {
                frames.sample(pane)
                try await Task.sleep(for: .milliseconds(5))
            }

            let states = Self.states(scenario.presses)
            let seen = frames.frames.map { $0.joined(separator: " ") }
            let stray = frames.frames.filter { !states.contains($0) }
            // Ctrl-` then Cmd-T: as the terminal's stand-in gives way to its daemon tab, the page shows before it for a frame or two
            // (`a b 2 c`, `a b 2 1 c`), then both settle in order (checked below). Only those frames are the known issue; any other is not.
            let known = scenario.presses == [.ctrlBacktick, .cmdT] ? [["a", "b", "2", "c"], ["a", "b", "2", "1", "c"]] : []
            // A close before the daemon made the tab: its daemon tab (unnamed, `?`) can show for a frame as the close lands, as a
            // same-turn close can in NewTabCloseInterleaveOrderTests (#36813); the others keep their order.
            let flashes = scenario.presses.contains(.closeFirst) ? stray.filter { $0.contains("?") && states.contains($0.filter { $0 != "?" }) } : []
            #expect(stray.allSatisfy { known.contains($0) || flashes.contains($0) }, "a new tab showed where no press puts it: \(stray.map { $0.joined(separator: " ") }); frames \(seen)")
            withKnownIssue("Ctrl-` then Cmd-T shows the page before the terminal for a frame as the terminal's stand-in is swapped", isIntermittent: true) {
                #expect(!stray.contains { known.contains($0) }, "the page showed before the terminal: \(seen)")
            } when: { !known.isEmpty }
            withKnownIssue("a closed new tab's daemon tab can show for a frame as its close lands (#36813)", isIntermittent: true) {
                #expect(flashes.isEmpty, "the closed tab showed: \(seen)")
            } when: { scenario.presses.contains(.closeFirst) }
            #expect(frames.frames.last == states.last,
                    "settled at \(frames.frames.last?.joined(separator: " ") ?? "-"), want \(states.last?.joined(separator: " ") ?? "-"); frames \(seen)")
        }
    }

    /// The +'s own invocation carries its mark; Cmd-T's (a key, the palette, the menu bar) carries none.
    @Test func onlyThePlusMarksItsInvocation() {
        var runs: [ActionInvocation] = []
        StripNewTab.request(pane: "p1") { runs.append($1) }
        #expect(runs.first?[StripNewTab.button]?.boolValue == true)
        #expect(ActionInvocation(origin: .user)[StripNewTab.button] == nil)
    }
}
