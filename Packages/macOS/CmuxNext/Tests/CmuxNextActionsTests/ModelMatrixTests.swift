@testable import CmuxNextActions
import Foundation
import Testing

/// The shared model-level case list (Tests/Matrix/cases.json, cx-gkyi1): one
/// file for the headless Swift runner (this suite), the headless core runner
/// (cmux-tui-core `mux::tests::matrix`) and the real-HID and monkey runners
/// (cx-hdyx4). This suite checks the file itself and that every case's entry
/// reaches its action: the palette, CLI, right-click menu, main menu or
/// default key binding the case names really offers that action. No window,
/// no daemon, no clock. Every failure starts with "MATRIX <case id>:".
@MainActor
@Suite struct ModelMatrixTests {
    static let codes: Set<String> = ["no-crash", "layout-valid", "items-kept", "item-set-kept", "count-delta", "order-is", "pane-has",
                                     "selected-is", "focus-on", "zoomed-is", "answers-within-ms", "restored-equal"]
    static let tiers: Set<String> = ["headless", "hid", "monkey"]
    static let inputs: Set<String> = ["mouse", "fast-drag", "keyboard"]
    /// Invariants only a runner with a real clock or a relaunch can check.
    static let liveOnlyCodes: Set<String> = ["answers-within-ms", "restored-equal"]

    let file: [String: Any]
    let cases: [[String: Any]]

    init() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matrix/cases.json")
        let data = try Data(contentsOf: url)
        file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        cases = try #require(file["cases"] as? [[String: Any]])
    }

    @Test func theFileDeclaresEveryCodeEntryAndPresetItUses() throws {
        #expect(file["version"] as? Int == 1)
        let table = try #require(file["invariants"] as? [String: String])
        #expect(Set(table.keys) == Self.codes, "the invariant table and this suite's codes differ")
        let entries = try #require(file["entries"] as? [String: [String: Any]])
        let presets = try #require(file["presets"] as? [String: [String: Any]])
        let words = try #require(file["vocabulary"] as? [String: Any])
        let vocabulary = try #require(words["of"] as? [String: String])
        let arguments = try #require(words["args"] as? [String: [String]])
        #expect(Set(arguments.keys) == Self.codes, "the argument table and this suite's codes differ")
        var ids = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? "?"
            #expect(id.range(of: #"^[a-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil, "MATRIX \(id): malformed id")
            #expect(ids.insert(id).inserted, "MATRIX \(id): duplicate id")
            let preset = item["state"] as? String ?? ""
            let objects = presets[preset]?["objects"] as? [String: String]
            #expect(objects != nil, "MATRIX \(id): unknown preset \(preset)")
            let tiers = Set(item["tiers"] as? [String] ?? [])
            #expect(!tiers.isEmpty && tiers.isSubset(of: Self.tiers), "MATRIX \(id): tiers \(tiers.sorted())")
            #expect(Set(item["inputs"] as? [String] ?? []).isSubset(of: Self.inputs), "MATRIX \(id): unknown input")
            let steps = Self.steps(of: item)
            #expect(!steps.isEmpty, "MATRIX \(id): no action and no steps")
            var expects = item["expect"] as? [[String: Any]] ?? []
            for step in steps {
                #expect(entries[step["entry"] as? String ?? ""] != nil, "MATRIX \(id): unknown entry \(step["entry"] ?? "nil")")
                expects += step["expect"] as? [[String: Any]] ?? []
            }
            for expect in expects {
                let code = expect["code"] as? String ?? ""
                #expect(Self.codes.contains(code), "MATRIX \(id): unknown code \(code)")
                // Exactly the arguments the code takes ("in?" is optional), and an `of` from the vocabulary.
                let args = arguments[code] ?? []
                let given = Set(expect.keys).subtracting(["code"])
                let required = Set(args.filter { !$0.hasSuffix("?") })
                let allowed = required.union(args.filter { $0.hasSuffix("?") }.map { String($0.dropLast()) })
                #expect(required.isSubset(of: given) && given.isSubset(of: allowed), "MATRIX \(id): \(code) takes \(args), got \(given.sorted())")
                if let of = expect["of"] as? String { #expect(vocabulary[of] != nil, "MATRIX \(id): \(code) of \(of)") }
            }
            if tiers.contains("headless") {
                #expect((item["core"] as? [[String: Any]])?.isEmpty == false, "MATRIX \(id): a headless case needs core steps")
                let live = expects.compactMap { $0["code"] as? String }.filter(Self.liveOnlyCodes.contains)
                #expect(live.isEmpty, "MATRIX \(id): \(live) has no headless meaning")
            }
            for ref in Self.refs(in: item) where ref != "$new" {
                #expect(objects?[ref] != nil, "MATRIX \(id): \(ref) is not an object of preset \(preset)")
            }
        }
    }

    /// Each case's entry offers its action: a surface entry through the
    /// catalog, a fixed entry (the strip's +, the sidebar's +, a drag) by
    /// its declared action list.
    @Test func everyEntryReachesItsAction() throws {
        let entries = try #require(file["entries"] as? [String: [String: Any]])
        let catalog = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id.rawValue, $0) })
        var failures: [String] = []
        for item in cases {
            let id = item["id"] as? String ?? "?"
            for step in Self.steps(of: item) {
                let entry = step["entry"] as? String ?? ""
                let action = (step["action"] as? [String: Any])?["id"] as? String ?? ""
                guard let spec = entries[entry] else { continue }
                if let fixed = spec["actions"] as? [String] {
                    if !fixed.contains(action) { failures.append("MATRIX \(id): \(entry) does not run \(action)") }
                    // A fixed entry's action is a catalog action unless the entry says it bypasses the registry.
                    if catalog[action] == nil, spec["bypassesRegistry"] as? Bool != true { failures.append("MATRIX \(id): \(action) is no action") }
                    continue
                }
                guard let descriptor = catalog[action] else {
                    failures.append("MATRIX \(id): \(action) is no action")
                    continue
                }
                let plan = descriptor.surfacePlan
                let offered = switch spec["surface"] as? String {
                case "palette": plan.palette.isOffered
                case "cli": plan.cli?.isOffered == true
                case "contextMenu": !plan.contextMenus.isEmpty
                case "mainMenu": descriptor.mainMenu != nil
                case "shortcut": descriptor.defaultShortcut != nil || descriptor.defaultChord != nil
                default: false
                }
                if !offered { failures.append("MATRIX \(id): \(action) has no \(entry) entry") }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) entries miss their action:\n\(failures.joined(separator: "\n"))")
    }

    /// The operations the matrix covers each have a case from every entry
    /// their action offers, so a new entry can't ship untested.
    @Test func everyOfferedEntryOfACoveredActionHasACase() throws {
        let catalog = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id.rawValue, $0) })
        let covered: [String] = ["newTab", "workspace.newAbove", "workspace.newBelow", "workspace.newAtTop", "workspace.newAtBottom",
                                 "moveWorkspaceUp", "moveWorkspaceDown", "moveSurfaceLeft", "moveSurfaceRight", "splitRight", "splitDown",
                                 "closePane", "toggleSplitZoom"]
        var seen: [String: Set<String>] = [:]
        for item in cases {
            for step in Self.steps(of: item) {
                if let action = (step["action"] as? [String: Any])?["id"] as? String, let entry = step["entry"] as? String {
                    seen[action, default: []].insert(entry)
                }
            }
        }
        var missing: [String] = []
        for action in covered {
            let descriptor = try #require(catalog[action], "MATRIX \(action): no such action")
            let plan = descriptor.surfacePlan
            let offered: [(String, Bool)] = [
                ("palette", plan.palette.isOffered), ("cli", plan.cli?.isOffered == true), ("context-menu", !plan.contextMenus.isEmpty),
                ("menu", descriptor.mainMenu != nil), ("shortcut", descriptor.defaultShortcut != nil || descriptor.defaultChord != nil),
            ]
            for (entry, isOffered) in offered where isOffered && seen[action]?.contains(entry) != true {
                missing.append("MATRIX \(action): no case from \(entry)")
            }
        }
        #expect(missing.isEmpty, "\(missing.count) offered entries without a case:\n\(missing.joined(separator: "\n"))")
    }

    static func steps(of item: [String: Any]) -> [[String: Any]] {
        if let steps = item["steps"] as? [[String: Any]] { return steps }
        guard let action = item["action"], let entry = item["entry"] else { return [] }
        return [["action": action, "entry": entry]]
    }

    /// Every `$name` string anywhere in the case but its prose notes.
    static func refs(in value: Any) -> Set<String> {
        switch value {
        case let text as String: text.hasPrefix("$") ? [text] : []
        case let array as [Any]: array.reduce(into: Set<String>()) { $0.formUnion(refs(in: $1)) }
        case let object as [String: Any]:
            object.filter { $0.key != "note" }.values.reduce(into: Set<String>()) { $0.formUnion(refs(in: $1)) }
        default: []
        }
    }
}
