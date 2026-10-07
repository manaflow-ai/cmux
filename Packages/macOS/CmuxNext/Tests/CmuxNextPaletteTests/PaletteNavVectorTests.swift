import CmuxNextPalette
import Foundation
import Testing

/// Runs the navigation vectors shared with the app test harness
/// (cmux-tui/crates/cmux-app-host/app-test/palette-nav-vectors.json, format
/// in its README) against `PaletteNavReducer`, so the Swift reducer and the
/// TypeScript port cannot drift.
@Suite struct PaletteNavVectorTests {
    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cmux-tui/crates/cmux-app-host/app-test/palette-nav-vectors.json")
    }

    @Test func everyVectorPasses() throws {
        let data = try Data(contentsOf: Self.vectorsURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count >= 25)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let failure = run(vector)
            #expect(failure == nil, "\(name): \(failure ?? "")")
        }
    }

    // MARK: Runner

    private func run(_ vector: [String: Any]) -> String? {
        let config = vector["config"] as? [String: Any] ?? [:]
        let graph = Self.graph(vector["graph"] as? [String: Any] ?? [:])
        let reducer = PaletteNavReducer(graph: graph, config: PaletteNavConfig(
            prefixEntry: config["prefixEntry"] as? Bool ?? true, keywordEntry: config["keywordEntry"] as? Bool ?? true,
            maxDepth: config["maxDepth"] as? Int ?? 8))
        var rowsByScope: [String: [PaletteNavRow]] = [:]
        for (scope, rows) in vector["rowsByScope"] as? [String: Any] ?? [:] { rowsByScope[scope] = Self.rows(rows) }
        var state = PaletteNavState()
        var lastEffects: [PaletteNavEffect] = []

        func send(_ event: PaletteNavEvent, answer: Bool) -> [PaletteNavEffect] {
            let produced = reducer.reduce(&state, event)
            var all = produced
            guard answer else { return all }
            for case .load(let levelID, let scope, _, let generation, _) in produced {
                all += send(.results(levelID: levelID, generation: generation, rows: rowsByScope[scope.rawValue] ?? [], replace: true,
                                     isFinal: true), answer: true)
            }
            return all
        }

        for step in vector["events"] as? [[String: Any]] ?? [] {
            if step["driver"] as? String == "setRows", let scope = step["scope"] as? String {
                rowsByScope[scope] = Self.rows(step["rows"] ?? [])
                continue
            }
            guard let event = Self.event(step) else { return "unknown event \(step)" }
            lastEffects = send(event, answer: step["answer"] as? Bool ?? true)
        }

        let expect = vector["expect"] as? [String: Any] ?? [:]
        let top = state.top
        if let isOpen = expect["isOpen"] as? Bool, isOpen != state.isOpen { return "isOpen \(state.isOpen)" }
        if let chips = expect["chips"] as? [String], chips != state.scopePath.map(\.rawValue) { return "chips \(state.scopePath)" }
        if expect.keys.contains("query"), (expect["query"] as? String) != top?.query { return "query \(top?.query ?? "nil")" }
        if expect.keys.contains("selection"), (expect["selection"] as? String) != top?.selection { return "selection \(top?.selection ?? "nil")" }
        if let queries = expect["queries"] as? [String], queries != state.levels.map(\.query) { return "queries \(state.levels.map(\.query))" }
        if let selections = expect["selections"] as? [Any],
           selections.map({ $0 as? String }) != state.levels.map(\.selection) { return "selections \(state.levels.map(\.selection))" }
        if let entry = expect["topEntry"] as? [String: Any], let top, !Self.matches(top.entry, entry) { return "topEntry \(top.entry)" }
        if let rows = expect["topRows"] as? [String], rows != top?.rows.map(\.id) { return "topRows \(top?.rows.map(\.id) ?? [])" }
        if expect.keys.contains("topContext"), (expect["topContext"] as? String) != top?.context { return "topContext \(top?.context ?? "nil")" }
        if let loading = expect["isLoading"] as? Bool, loading != top?.isLoading { return "isLoading \(top?.isLoading ?? false)" }
        if let problems = expect["graphProblems"] as? Int, problems != graph.problems.count { return "graphProblems \(graph.problems)" }
        if let effects = expect["lastEffects"] as? [[String: Any]] {
            let expected = effects.compactMap(Self.effect)
            if expected.count != effects.count { return "unknown expected effect \(effects)" }
            if expected != lastEffects { return "lastEffects \(lastEffects)" }
        }
        if let effects = expect["lastEffectsInclude"] as? [[String: Any]] {
            for effect in effects.compactMap(Self.effect) where !lastEffects.contains(effect) { return "missing effect \(effect) in \(lastEffects)" }
        }
        return nil
    }

    // MARK: Decoding

    private static func graph(_ json: [String: Any]) -> PaletteScopeGraph {
        let root = PaletteScopeDescriptor(id: .root, title: "Root", symbol: "command", placeholder: "",
                                          emptyQuerySelection: json["rootEmptyQuerySelection"] as? Int ?? 0)
        let scopes = (json["scopes"] as? [[String: Any]] ?? []).map { scope -> PaletteScopeDescriptor in
            let parents: PaletteScopeDescriptor.Parents
            switch scope["parents"] {
            case let list as [String]: parents = .only(Set(list.map { PaletteScopeID($0) }))
            case let text as String where text == "anywhere": parents = .anywhere
            default: parents = .root
            }
            let id = scope["id"] as? String ?? ""
            return PaletteScopeDescriptor(id: PaletteScopeID(id), title: id, symbol: "circle", placeholder: "", prefix: scope["prefix"] as? String,
                                          keywords: scope["keywords"] as? [String] ?? [], parents: parents,
                                          emptyQuerySelection: scope["emptyQuerySelection"] as? Int ?? 0)
        }
        return PaletteScopeGraph(root: root, scopes: scopes)
    }

    private static func rows(_ json: Any) -> [PaletteNavRow] {
        (json as? [[String: Any]] ?? []).map { row in
            PaletteNavRow(id: row["id"] as? String ?? "", enters: (row["enters"] as? String).map { PaletteScopeID($0) },
                          drills: (row["drills"] as? String).map { PaletteScopeID($0) }, isEnabled: row["isEnabled"] as? Bool ?? true)
        }
    }

    private static func event(_ json: [String: Any]) -> PaletteNavEvent? {
        switch json["event"] as? String {
        case "open": .open(scope: (json["scope"] as? String).map { PaletteScopeID($0) }, query: json["query"] as? String ?? "")
        case "close": .close
        case "setQuery": .setQuery(json["text"] as? String ?? "")
        case "backspaceOnEmpty": .backspaceOnEmpty
        case "tab": .tab
        case "shiftTab": .shiftTab
        case "escape": .escape
        case "popTo": .popTo(json["index"] as? Int ?? 0)
        case "activate": .activate(json["rowID"] as? String)
        case "push": .push(PaletteScopeID(json["scope"] as? String ?? ""), row: json["row"] as? String, query: json["query"] as? String ?? "")
        case "move": .move(json["delta"] as? Int ?? 0)
        case "select": .select(json["rowID"] as? String ?? "")
        case "refresh": .refresh
        case "results":
            .results(levelID: json["levelID"] as? Int ?? 0, generation: json["generation"] as? Int ?? 0, rows: rows(json["rows"] ?? []),
                     replace: json["replace"] as? Bool ?? true, isFinal: json["isFinal"] as? Bool ?? true,
                     emptyQuerySelection: json["emptyQuerySelection"] as? Int)
        default: nil
        }
    }

    private static func effect(_ json: [String: Any]) -> PaletteNavEffect? {
        switch json["effect"] as? String {
        case "load":
            .load(levelID: json["levelID"] as? Int ?? 0, scope: PaletteScopeID(json["scope"] as? String ?? ""), query: json["query"] as? String ?? "",
                  generation: json["generation"] as? Int ?? 0, context: json["context"] as? String)
        case "cancel": .cancel(levelID: json["levelID"] as? Int ?? 0)
        case "run": .run(levelID: json["levelID"] as? Int ?? 0, rowID: json["rowID"] as? String ?? "")
        case "openActions": .openActions(rowID: json["rowID"] as? String ?? "")
        case "dismiss": .dismiss
        case "announceEntered": .announceEntered(PaletteScopeID(json["scope"] as? String ?? ""))
        case "announceLeft": .announceLeft(to: PaletteScopeID(json["to"] as? String ?? ""))
        case "refused" where json["reason"] as? String == "depthLimit": .refused(.depthLimit)
        default: nil
        }
    }

    private static func matches(_ entry: PaletteNavLevel.Entry, _ json: [String: Any]) -> Bool {
        let value = json["value"] as? String
        switch (entry, json["entry"] as? String) {
        case (.root, "root"), (.opened, "opened"): return true
        case (.prefix(let text), "prefix"), (.keyword(let text), "keyword"), (.row(let text), "row"), (.drill(let text), "drill"): return text == value
        case (.command(let row), "command"): return row == value
        default: return false
        }
    }
}
