@testable import CmuxNextApp
import Testing

/// Random event sequences through the focus reducer, checking the
/// invariants of plans/cmux-next/focus.md section 6 after every step.
struct FocusStressTests {
    /// Deterministic generator (SplitMix64) so failures reproduce.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func bool() -> Bool { next() & 1 == 0 }
    }

    static let workspaces = ["w1", "w2"]
    static let paneIDs = ["p1", "p2", "p3", "p4"]
    static let tabIDs = ["t1", "t2", "t3", "t4", "t5", "t6"]

    static func randomTopology(_ random: inout Random) -> FocusTopology {
        var used = Set<String>()
        var panes: [FocusTopology.Pane] = []
        for pane in paneIDs where random.int(3) != 0 {
            var tabs: [FocusTopology.Tab] = []
            for tab in tabIDs where !used.contains(tab) && random.int(3) == 0 {
                used.insert(tab)
                let kind: FocusTopology.Kind = random.int(4) == 0 ? .browser : .terminal
                tabs.append(FocusTopology.Tab(id: tab, surface: "s-\(tab)", kind: kind))
            }
            panes.append(FocusTopology.Pane(id: pane, tabs: tabs, selected: tabs.isEmpty ? nil : tabs[random.int(tabs.count)].id))
        }
        return FocusTopology(workspace: workspaces[random.int(workspaces.count)], panes: panes)
    }

    static func randomEvent(_ random: inout Random, state: FocusState) -> FocusEvent {
        let pane = paneIDs[random.int(paneIDs.count)]
        let tab = tabIDs[random.int(tabIDs.count)]
        let sources: [FocusEvent.Source] = [.mouse, .keyboard, .cli, .palette, .programmatic]
        let source = sources[random.int(sources.count)]
        let overlays: [FocusState.Overlay] = [.palette, .sheet, .rename, .groupEditor]
        let overlay = overlays[random.int(overlays.count)]
        switch random.int(17) {
        case 0, 1, 2: return .topology(randomTopology(&random))
        case 3: return .focusPane(pane, source: source)
        case 4: return .selectTab(pane: pane, tab: tab, source: source)
        case 5: return .focusTarget([.content, .addressBar, .findBar, .sidebarField][random.int(4)], source: source)
        case 6:
            let responders: [FocusEvent.Responder] = [.content(pane: pane), .addressBar(pane: pane), .findBar(pane: pane),
                                                      .sidebar, .sidebarField, .textField, .windowOrNone]
            return .responder(responders[random.int(responders.count)], source: source)
        case 7: return .windowKey(random.bool())
        case 8: return .overlayOpened(overlay)
        case 9: return .overlayClosed(overlay)
        case 10: return .beginIntent
        case 11: return .expect(random.bool() ? .surface("s-\(tab)") : .tab(tab), target: random.bool() ? .content : .addressBar,
                                generation: random.bool() ? state.generation : state.generation &- 1)
        case 12: return .dragBegan(tabs: [tab], pane: pane)
        case 13: return .dragEnded([.cancelled, .dropped(tabs: [tab], awayFrom: random.bool() ? pane : nil), .movedAway][random.int(3)])
        case 14: return .contentPresented(pane: pane)
        case 15: return .toggleBrowserFocusMode(tab: random.bool() ? nil : tab)
        default: return .appActive(random.bool())
        }
    }

    static func checkInvariants(_ state: FocusState, after event: FocusEvent, step: Int) {
        let resolved = state.resolved
        let context = "step \(step) after \(event)"
        if let top = state.overlays.last {
            #expect(resolved == .overlay(top), "\(context)")
        }
        if let pane = resolved.pane {
            #expect(state.topology.contains(pane: pane), "resolved pane not in topology, \(context)")
            #expect(pane == state.pane, "\(context)")
        }
        if let tab = resolved.tab, let pane = resolved.pane {
            #expect(state.topology.pane(pane)?.selected == tab, "resolved tab is not the selection, \(context)")
        }
        if let pane = state.pane {
            #expect(state.topology.contains(pane: pane), "focused pane \(pane) not in topology, \(context)")
        } else {
            #expect(state.topology.panes.isEmpty || !state.target.isPaneScoped, "no focused pane with panes present, \(context)")
        }
        if let expectation = state.expectation {
            #expect(expectation.generation == state.generation, "stale expectation survived, \(context)")
        }
        #expect(state.browserFocusMode.isSubset(of: state.topology.allTabIDs) || !isTopology(event), "\(context)")
        switch resolved {
        case .addressBar(let pane, _), .findBar(let pane, _), .browserPage(let pane, _):
            #expect(state.topology.pane(pane)?.selectedTab?.kind == .browser, "\(context)")
        case .terminal(let pane, _):
            #expect(state.topology.pane(pane)?.selectedTab?.kind == .terminal, "\(context)")
        default:
            break
        }
    }

    static func isTopology(_ event: FocusEvent) -> Bool {
        if case .topology = event { true } else { false }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func randomSequencesKeepTheInvariants(seed: UInt64) {
        var random = Random(state: seed)
        var state = FocusState()
        for step in 0..<2_000 {
            let event = Self.randomEvent(&random, state: state)
            let (next, effects) = FocusReducer.reduce(state, event)
            Self.checkInvariants(next, after: event, step: step)
            // Every select effect names a tab of its pane when the pane is shown.
            for case .select(let pane, let tab) in effects where next.topology.contains(pane: pane) && next.topology.workspace == state.topology.workspace {
                if case .selectTab = event { continue }
                #expect(next.topology.pane(pane)?.tab(tab) != nil, "select names a missing tab, step \(step)")
            }
            // Reducing is deterministic.
            #expect(FocusReducer.reduce(state, event).0 == next)
            state = next
        }
    }
}
