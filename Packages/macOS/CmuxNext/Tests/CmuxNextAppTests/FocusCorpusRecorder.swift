@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// TEMPORARY, never landed: records (event -> state, effects) steps from the
/// Swift FocusReducer for the Rust conformance corpus (cmux-focus-core).
@MainActor
struct FocusCorpusRecorder {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
        mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
    }

    static let workspaces = ["w1", "w2", "w3"]
    static let paneIDs = ["p1", "p2", "p3", "p4", "p5"]
    static let tabIDs = (1...10).map { "t\($0)" }
    static let kinds: [FocusTopology.Kind] = [.terminal, .browser, .agent, .page, .conversation, .other, .browser, .terminal, .browser, .terminal]
    static func tab(_ id: String) -> FocusTopology.Tab {
        let index = Int(id.dropFirst())! - 1
        return FocusTopology.Tab(id: id, surface: index % 3 == 2 ? nil : "s\(index + 1)", kind: kinds[index])
    }

    static func randomTopology(_ rng: inout Rng, workspace: String?) -> FocusTopology {
        let count = rng.int(5)
        let panes = Array(paneIDs.shuffled(using: &rng).prefix(count))
        var tabs = tabIDs.shuffled(using: &rng)
        var models: [FocusTopology.Pane] = []
        for pane in panes {
            let n = min(tabs.count, rng.int(4))
            let mine = Array(tabs.prefix(n)); tabs.removeFirst(n)
            var selected = mine.isEmpty ? nil : rng.pick(mine)
            if rng.chance(5) { selected = nil }
            if rng.chance(3) { selected = rng.pick(tabIDs) }
            models.append(FocusTopology.Pane(id: pane, tabs: mine.map(tab), selected: selected))
        }
        return FocusTopology(workspace: workspace, panes: models, screens: randomScreens(&rng, panes: panes))
    }

    static func randomScreens(_ rng: inout Rng, panes: [String]) -> [[FocusTopology.Column]] {
        if rng.chance(40) || panes.isEmpty { return [] }
        var rest = panes
        var screens: [[FocusTopology.Column]] = []
        let columnIDs = ["c1", "c2", "c3", "c4"].shuffled(using: &rng)
        var columnIndex = 0
        while !rest.isEmpty {
            var columns: [FocusTopology.Column] = []
            for _ in 0...rng.int(3) where !rest.isEmpty {
                let n = 1 + rng.int(min(3, rest.count))
                let id = rng.chance(5) ? "c1" : columnIDs[columnIndex % columnIDs.count]
                columnIndex += 1
                columns.append(FocusTopology.Column(id: id, panes: Array(rest.prefix(n))))
                rest.removeFirst(n)
            }
            screens.append(columns)
        }
        return screens
    }

    /// A small change to `topology`: close a pane, move a tab, select, add.
    static func mutate(_ topology: FocusTopology, _ rng: inout Rng) -> FocusTopology {
        var next = topology
        switch rng.int(6) {
        case 0 where !next.panes.isEmpty:
            let index = rng.int(next.panes.count)
            let removed = next.panes.remove(at: index).id
            next.screens = next.screens.map { $0.map { FocusTopology.Column(id: $0.id, panes: $0.panes.filter { $0 != removed }) } }
            if rng.chance(50) { next.screens = next.screens.map { $0.filter { !$0.panes.isEmpty } }.filter { !$0.isEmpty } }
        case 1 where next.panes.count > 1:
            let from = rng.int(next.panes.count), to = rng.int(next.panes.count)
            if from != to, !next.panes[from].tabs.isEmpty {
                let tab = next.panes[from].tabs.removeFirst()
                next.panes[to].tabs.append(tab)
                if rng.chance(60) { next.panes[to].selected = tab.id }
                if next.panes[from].selected == tab.id { next.panes[from].selected = next.panes[from].tabs.first?.id }
            }
        case 2 where !next.panes.isEmpty:
            let index = rng.int(next.panes.count)
            next.panes[index].selected = next.panes[index].tabs.isEmpty ? nil : rng.pick(next.panes[index].tabs).id
        case 3:
            let free = paneIDs.filter { !next.contains(pane: $0) }
            let used = Set(next.panes.flatMap { $0.tabs.map(\.id) })
            let freeTabs = tabIDs.filter { !used.contains($0) }
            if let pane = free.first, let tabID = freeTabs.first {
                next.panes.insert(FocusTopology.Pane(id: pane, tabs: [tab(tabID)], selected: tabID), at: rng.int(next.panes.count + 1))
                if !next.screens.isEmpty {
                    let s = rng.int(next.screens.count)
                    if !next.screens[s].isEmpty {
                        let c = rng.int(next.screens[s].count)
                        next.screens[s][c].panes.append(pane)
                    }
                }
            }
        case 4:
            next = randomTopology(&rng, workspace: rng.chance(10) ? nil : rng.pick(workspaces))
        default:
            next = randomTopology(&rng, workspace: next.workspace)
        }
        return next
    }

    static let sources: [FocusEvent.Source] = [.mouse, .keyboard, .cli, .palette, .programmatic]
    static let targets: [FocusState.Target] = [.content, .addressBar, .findBar, .devTools, .sidebar(keyboard: true),
                                               .sidebar(keyboard: false), .sidebarField, .textField, .none]
    static let overlays: [FocusState.Overlay] = [.palette, .sheet, .rename, .groupEditor]

    static func randomEvent(_ state: FocusState, _ rng: inout Rng) -> FocusEvent {
        let shownPanes = state.topology.panes.map(\.id)
        func somePane() -> String { !shownPanes.isEmpty && rng.chance(80) ? rng.pick(shownPanes) : rng.pick(paneIDs) }
        func someTab() -> String {
            let shown = state.topology.panes.flatMap { $0.tabs.map(\.id) }
            return !shown.isEmpty && rng.chance(80) ? rng.pick(shown) : rng.pick(tabIDs)
        }
        func someWorkspace() -> String? { rng.chance(60) ? nil : rng.chance(50) ? state.topology.workspace ?? "w1" : rng.pick(workspaces) }
        let source = rng.pick(sources)
        switch rng.int(100) {
        case 0..<22: return .topology(mutate(state.topology, &rng))
        case 22..<31: return .focusPane(somePane(), workspace: someWorkspace(), source: source)
        case 31..<40: return .selectTab(pane: somePane(), tab: someTab(), workspace: someWorkspace(), source: source)
        case 40..<48: return .focusTarget(rng.pick(targets), source: source)
        case 48..<60:
            let pane = somePane()
            let responder: FocusEvent.Responder = rng.pick([.content(pane: pane), .addressBar(pane: pane), .findBar(pane: pane),
                                                           .devTools(pane: pane), .sidebar, .sidebarField, .textField, .windowOrNone])
            return .responder(responder, source: source)
        case 60..<64: return .windowKey(rng.chance(50))
        case 64..<66: return .appActive(rng.chance(50))
        case 66..<70: return .overlayOpened(rng.pick(overlays))
        case 70..<74: return .overlayClosed(state.overlays.isEmpty || rng.chance(20) ? rng.pick(overlays) : state.overlays.last!)
        case 74..<78: return .beginIntent
        case 78..<84:
            let key: FocusState.Expectation.Key = rng.chance(50) ? .tab(someTab()) : .surface("s\(1 + rng.int(10))")
            let generation = rng.chance(80) ? state.generation : state.generation &+ UInt64(rng.int(3)) &- 1
            return .expect(key, target: rng.pick(targets), awayFrom: rng.chance(30) ? somePane() : nil, generation: generation)
        case 84..<87: return .dragBegan(tabs: [someTab()], pane: somePane())
        case 87..<91:
            let outcome: FocusEvent.DragOutcome = switch rng.int(3) {
            case 0: .cancelled
            case 1: .dropped(tabs: rng.chance(10) ? [] : [someTab(), someTab()], awayFrom: rng.chance(40) ? somePane() : nil)
            default: .movedAway
            }
            return .dragEnded(outcome)
        case 91..<94: return .contentPresented(pane: somePane())
        case 94..<97: return .toggleBrowserFocusMode(tab: rng.chance(50) ? nil : someTab())
        case 97..<99: return .sidebarVisibility(hidden: rng.chance(50))
        default: return .restoredPane(somePane(), workspace: rng.pick(workspaces))
        }
    }

    // MARK: JSON in the synthesized Codable shape

    static func json<T: Encodable>(_ value: T) -> Any {
        let data = try! JSONEncoder().encode(value)
        return try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func json(_ resolved: FocusState.Resolved) -> Any {
        func pt(_ name: String, _ pane: String, _ tab: String) -> Any { [name: ["pane": pane, "tab": tab]] }
        switch resolved {
        case .terminal(let p, let t): return pt("terminal", p, t)
        case .browserPage(let p, let t): return pt("browserPage", p, t)
        case .addressBar(let p, let t): return pt("addressBar", p, t)
        case .findBar(let p, let t): return pt("findBar", p, t)
        case .devTools(let p, let t): return pt("devTools", p, t)
        case .agentPage(let p, let t): return pt("agentPage", p, t)
        case .page(let p, let t): return pt("page", p, t)
        case .conversation(let p, let t): return pt("conversation", p, t)
        case .emptyPane(let p): return ["emptyPane": ["pane": p]]
        case .sidebar: return ["sidebar": [String: Any]()]
        case .sidebarField: return ["sidebarField": [String: Any]()]
        case .textField: return ["textField": [String: Any]()]
        case .overlay(let o): return ["overlay": ["_0": o.rawValue]]
        case .none: return ["none": [String: Any]()]
        }
    }

    static func json(_ effect: FocusEffect) -> Any {
        switch effect {
        case .select(let pane, let tab): return ["select": ["pane": pane, "tab": tab]]
        case .revealPane(let pane): return ["revealPane": ["_0": pane]]
        case .moveResponder(let resolved): return ["moveResponder": ["_0": json(resolved)]]
        case .publishContext(let context): return ["publishContext": ["_0": json(context)]]
        case .browserFocusMode(let tab, let active): return ["browserFocusMode": ["tab": tab, "active": active] as [String: Any]]
        }
    }

    static func stateJSON(_ state: FocusState) -> [String: Any] {
        var object = json(state) as! [String: Any]
        object["derived"] = [
            "resolved": json(state.resolved),
            "underlying": json(state.underlying),
            "context": json(state.context),
            "browserFocusModeActive": state.isBrowserFocusModeActive,
            "recentPanes": state.recentPanes,
        ] as [String: Any]
        return object
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        return (try? JSONSerialization.data(withJSONObject: a, options: options)) == (try? JSONSerialization.data(withJSONObject: b, options: options))
    }

    @Test func record() throws { try Self.recordAll() }

    static func recordAll() throws {
        var sequences: [Any] = []
        let count = Int(ProcessInfo.processInfo.environment["FOCUS_CORPUS_SEQUENCES"] ?? "") ?? 120
        let length = 28
        for seed in 0..<count {
            var rng = Rng(state: UInt64(seed) &* 7919 &+ 17)
            var state = FocusState()
            state.closeFocus = rng.chance(50) ? .previousNeighbor : .mostRecent
            var previous = stateJSON(state)
            let initial = previous
            var steps: [Any] = []
            for _ in 0..<length {
                let event = rng.chance(15) && !state.topology.panes.isEmpty && state.topology.workspace != nil
                    ? FocusEvent.topology(randomTopology(&rng, workspace: rng.pick(workspaces)))
                    : randomEvent(state, &rng)
                let (next, effects) = FocusReducer.reduce(state, event)
                let current = stateJSON(next)
                // Only the top-level keys that changed; null = the key is gone.
                var diff: [String: Any] = [:]
                for key in Set(previous.keys).union(current.keys) where !same(previous[key], current[key]) {
                    diff[key] = current[key] ?? NSNull()
                }
                if case .topology(let topology) = event, next.topology == topology, diff["topology"] != nil {
                    diff["topology"] = "=event"
                }
                steps.append(["event": json(event), "effects": effects.map { json($0) }, "state": diff,
                              "changesView": event.changesView] as [String: Any])
                previous = current
                state = next
            }
            sequences.append(["seed": seed, "initial": initial, "steps": steps] as [String: Any])
        }
        let corpus: [String: Any] = ["format": 1, "source": "Swift FocusReducer, TypeAheadQueue, ChildWindowKeyRule",
                                     "sequences": sequences, "childWindow": Self.childWindowCases(), "typeAhead": Self.typeAheadCases()]
        let data = try JSONSerialization.data(withJSONObject: corpus, options: [.sortedKeys])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try data.write(to: root.appendingPathComponent("focus-corpus.json"))
        print("focus corpus: \(sequences.count) sequences, \(data.count) bytes at \(root.path)/focus-corpus.json")
    }
}

extension FocusCorpusRecorder {
    /// Every combination of the facts.
    static func childWindowCases() -> [Any] {
        var cases: [Any] = []
        let parents: [(ChildWindowKeyRule.Parent, String)] = [(.thisWindow, "thisWindow"), (.none, "none"), (.other, "other")]
        for (parent, name) in parents {
            for bits in 0..<64 {
                let b = { (i: Int) in bits & (1 << i) != 0 }
                let facts = ChildWindowKeyRule.Facts(parent: parent, isPanel: b(0), isChromiumPage: b(1), isDevTools: b(2),
                                                     clicked: b(3), overPane: b(4), thisWindowIsActive: b(5))
                let decision: String = switch ChildWindowKeyRule.decide(facts) {
                case .ignore: "ignore"
                case .devTools: "devTools"
                case .unchosenPage: "unchosenPage"
                case .chosenPage: "chosenPage"
                case .reapply: "reapply"
                }
                cases.append(["facts": ["parent": [name: [String: Any]()], "isPanel": b(0), "isChromiumPage": b(1), "isDevTools": b(2),
                                        "clicked": b(3), "overPane": b(4), "thisWindowIsActive": b(5)] as [String: Any],
                              "decision": decision, "shouldReclaim": ChildWindowKeyRule.shouldReclaim(facts)] as [String: Any])
            }
        }
        return cases
    }

    /// Seeded op sequences on one queue; times are nanoseconds after a base instant.
    static func typeAheadCases() -> [Any] {
        let pool = ["a", "b", "Z", " ", "1", "é", "e\u{301}", "\u{301}", "👍", "👍🏽", "🇯🇵", "한", "ab", "xyz", String(repeating: "q", count: 100)]
        var sequences: [Any] = []
        for seed in 0..<80 {
            var rng = Rng(state: UInt64(seed) &* 104_729 &+ 3)
            var queue = TypeAheadQueue()
            let base = ContinuousClock.now
            var now: Int64 = 0
            var ops: [Any] = []
            for _ in 0..<30 {
                now += Int64(rng.int(4)) * Int64(rng.pick([1, 1_000_000, 400_000_000, 700_000_000]))
                if rng.chance(3) { now += 1_000_000_000 }
                let instant = base + .nanoseconds(now)
                let surface = rng.chance(80) ? "a" : "b"
                var op: [String: Any]
                var result: [String: Any] = [:]
                switch rng.int(10) {
                case 0..<5:
                    let characters = rng.pick(pool)
                    queue.append(characters, surface: surface, now: instant)
                    op = ["append": ["characters": characters, "surface": surface, "nowNs": now] as [String: Any]]
                case 5..<7:
                    queue.deleteBackward(surface: surface)
                    op = ["deleteBackward": ["surface": surface]]
                case 7:
                    result["text"] = queue.take(surface: surface, now: instant).map { $0 as Any } ?? NSNull()
                    op = ["take": ["surface": surface, "nowNs": now] as [String: Any]]
                case 8:
                    result["pending"] = queue.pending(for: surface)
                    op = ["pending": ["surface": surface]]
                default:
                    queue.drop()
                    op = ["drop": [String: Any]()]
                }
                result["surface"] = queue.surface.map { $0 as Any } ?? NSNull()
                result["queued"] = queue.text
                ops.append(["op": op, "result": result] as [String: Any])
            }
            sequences.append(["seed": seed, "ops": ops] as [String: Any])
        }
        return sequences
    }
}

extension FocusCorpusRecorder.Rng: RandomNumberGenerator {}
