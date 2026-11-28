@testable import CmuxNextSettings
import Foundation
import Testing

/// Step B of the keymap slice: `ShortcutKeymapPreset`, `ShortcutDigitScheme`, `ClassicShortcutImport` and the
/// keymap file import now ask cmux-config's `keymap.*` ops. ``Oracle`` is the Swift they ran before the move,
/// kept here only as the reference; each test feeds both the same inputs and expects the same answers.
@Suite struct KeymapRustParityTests {
    /// Binding maps that cover a fresh file, each preset applied, presets mixed, hand-set values, parsed-equal
    /// spellings, legacy keys and the digit actions.
    static let corpus: [[String: JSONValue]] = {
        var maps: [[String: JSONValue]] = [[:]]
        for preset in Oracle.Preset.allCases { maps.append(Dictionary(uniqueKeysWithValues: preset.overrides.map { ($0.key, $0.value) })) }
        for scheme in Oracle.Digit.allCases { maps.append(Dictionary(uniqueKeysWithValues: scheme.overrides.map { ($0.key, $0.value) })) }
        maps += [
            ["selectSurfaceByNumber": "cmd+1", "renameTab": "cmd+shift+i"],
            ["selectSurfaceByNumber": "cmd+9", "newTab": ["ctrl+b", "c"]],
            ["toggleTerminalCopyMode": "shift+cmd+c", "resizePaneLeft": "ctrl+cmd+left"],
            ["space.selectByNumber": "opt+ctrl+1", "selectSurfaceByNumber": "ctrl+1"],
            ["space.selectByNumber": "ctrl+1"],
            ["space.selectByNumber": ["ctrl+b", "1"], "selectSurfaceByNumber": "ctrl+opt+1"],
            ["selectSurfaceByNumber": "not a key"],
            ["closeOtherTabsInPane": "cmd+opt+w", "focusLeft": "cmd+h"],
            ["selectWorkspaceByNumber": "cmd+opt+1", "closeTab": ["ctrl+b", "x"], "splitRight": .null],
        ]
        return maps
    }()

    @Test func presetPlansAndActiveMatchTheSwiftTheyReplaced() {
        for bindings in Self.corpus {
            for preset in ShortcutKeymapPreset.allCases {
                let rust = preset.plan(from: bindings)
                let swift = Oracle.Preset(rawValue: preset.rawValue)!.plan(from: bindings)
                #expect(rust.changes == swift.changes, "\(preset) \(bindings)")
                #expect(rust.kept == swift.kept, "\(preset) \(bindings)")
                #expect(rust.edits == Oracle.edits(swift.changes), "\(preset) \(bindings)")
            }
            #expect(ShortcutKeymapPreset.active(in: bindings)?.rawValue == Oracle.Preset.active(in: bindings)?.rawValue, "\(bindings)")
        }
    }

    @Test func digitPlansAndActiveMatchTheSwiftTheyReplaced() {
        for bindings in Self.corpus {
            for scheme in ShortcutDigitScheme.allCases {
                let rust = scheme.plan(from: bindings)
                let swift = Oracle.Digit(rawValue: scheme.rawValue)!.plan(from: bindings)
                #expect(rust.changes == swift.changes, "\(scheme) \(bindings)")
                #expect(rust.kept == swift.kept, "\(scheme) \(bindings)")
                #expect(rust.edits == Oracle.edits(swift.changes), "\(scheme) \(bindings)")
            }
            #expect(ShortcutDigitScheme.active(in: bindings)?.rawValue == Oracle.Digit.active(in: bindings)?.rawValue, "\(bindings)")
        }
    }

    @Test func classicStoredShortcutsMatchTheSwiftTheyReplaced() throws {
        let stored: [[String: Any]] = [
            ["key": "b", "command": true, "option": true, "control": true],
            ["key": "b", "control": true, "chordKey": "p"],
            ["key": "b", "control": true, "chordKey": "p", "chordShift": true, "chordCommand": 1],
            ["key": ""],
            ["key": "media.playpause"],
            ["key": "left", "command": true],
            ["key": "l", "option": true],
            ["key": "k", "command": 1, "shift": 0, "option": 2],
            ["key": "x", "command": true, "chordKey": "media.next"],
            ["command": true],
            ["key": "é", "command": true],
        ]
        for object in stored {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(ClassicShortcutImport.binding(stored: data) == Oracle.classicBinding(stored: data), "\(object)")
        }
        #expect(ClassicShortcutImport.binding(stored: Data("not json".utf8)) == nil)
    }

    @Test func keymapFileImportEditsMatchTheSwiftTheyReplaced() throws {
        let files: [JSONValue] = [
            .object([:]),
            ["shortcuts": ["bindings": ["newTab": "cmd+t"], "tiers": ["a": "b"]]],
            ["bindings": ["newTab": "cmd+t"], "when": ["x": "y"]],
            ["newTab": "cmd+t", "closeTab": ["ctrl+b", "x"]],
            ["app": ["keyStyle": "emacs", "shortcutLayout": "dvorak", "theme": "dark"], "shortcuts": ["bindings": [:]]],
            ["app": ["keyStyle": "vim"]],
        ]
        for file in files {
            let reply = try SettingsRust.call("keymap.import_edits", ["value": file])
            let rust = SettingsController.fileEdits(reply).map { Oracle.Edit(path: $0.path, value: $0.value) }
            // Swift walked a dictionary in no order; Rust sorts the `shortcuts` members.
            #expect(Set(rust) == Set(try Oracle.importEdits(file)), "\(file)")
        }
        #expect(throws: SettingsRust.Failure.self) { try SettingsRust.call("keymap.import_edits", ["value": "text"]) }
    }

    @Test func mergedBindingsMatchTheSwiftTheyReplaced() {
        let sections: [JSONValue] = [
            .null, .object([:]),
            ["newTab": "cmd+t", "bindings": ["newTab": "cmd+y", "closeTab": "cmd+w"], "tiers": [:], "when": [:],
             "showModifierHoldHints": true],
            ["bindings": "bad", "focusLeft": "cmd+h"],
        ]
        for section in sections {
            let rust = SettingsRust.answer("keymap.bindings", ["shortcuts": section])["bindings"]?.objectValue ?? [:]
            #expect(rust == Oracle.bindings(section), "\(section)")
        }
    }
}

/// The Swift the `keymap.*` ops replaced, verbatim but for names (step B), as the parity reference.
private enum Oracle {
    struct Edit: Hashable { let path: [String]; let value: JSONValue? }

    static func edits(_ changes: [ShortcutKeymapPlan.Change]) -> [ShortcutKeymapPlan.Edit] {
        changes.flatMap { change -> [ShortcutKeymapPlan.Edit] in
            var out = [ShortcutKeymapPlan.Edit(path: ["shortcuts", "bindings", change.actionID], value: change.write)]
            if change.write == nil { out.append(.init(path: ["shortcuts", change.actionID], value: nil)) }
            return out
        }
    }

    enum Preset: String, CaseIterable {
        case cmux, iTerm2 = "iterm2", terminal, tmux

        var overrides: KeyValuePairs<String, JSONValue> {
            switch self {
            case .cmux: return [:]
            case .iTerm2:
                return ["selectSurfaceByNumber": "cmd+1", "selectWorkspaceByNumber": "cmd+opt+1", "toggleTerminalCopyMode": "cmd+shift+c",
                        "resizePaneLeft": "cmd+ctrl+left", "resizePaneRight": "cmd+ctrl+right", "resizePaneUp": "cmd+ctrl+up",
                        "resizePaneDown": "cmd+ctrl+down"]
            case .terminal: return ["closeOtherTabsInPane": "cmd+opt+w", "renameTab": "cmd+shift+i"]
            case .tmux:
                return ["newTab": ["ctrl+b", "c"], "closeTab": ["ctrl+b", "x"], "closeWorkspace": ["ctrl+b", "shift+7"],
                        "nextSidebarTab": ["ctrl+b", "n"], "prevSidebarTab": ["ctrl+b", "p"], "selectWorkspaceByNumber": ["ctrl+b", "1"],
                        "renameWorkspace": ["ctrl+b", ","], "goToWorkspace": ["ctrl+b", "w"], "splitRight": ["ctrl+b", "shift+5"],
                        "splitDown": ["ctrl+b", "shift+'"], "focusLeft": ["ctrl+b", "left"], "focusRight": ["ctrl+b", "right"],
                        "focusUp": ["ctrl+b", "up"], "focusDown": ["ctrl+b", "down"], "focusNextPane": ["ctrl+b", "o"],
                        "toggleSplitZoom": ["ctrl+b", "z"], "toggleTerminalCopyMode": ["ctrl+b", "["]]
            }
        }

        func binding(for id: String) -> ShortcutBinding? {
            overrides.first { $0.key == id }.flatMap { ShortcutBindingFormat.parse($0.value) }
        }

        var actionIDs: [String] {
            var seen = Set<String>()
            return (overrides.map(\.key) + Self.allCases.flatMap { $0.overrides.map(\.key) }).filter { seen.insert($0).inserted }
        }

        func plan(from bindings: [String: JSONValue]) -> (changes: [ShortcutKeymapPlan.Change], kept: [String]) {
            var changes: [ShortcutKeymapPlan.Change] = []
            var kept: [String] = []
            for id in actionIDs {
                let current = bindings[id].flatMap(ShortcutBindingFormat.parse)
                let owned = current.map { value in Self.allCases.contains { $0.binding(for: id) == value } } ?? false
                if let target = overrides.first(where: { $0.key == id }) {
                    guard current != ShortcutBindingFormat.parse(target.value) else { continue }
                    guard bindings[id] == nil || owned else { kept.append(id); continue }
                    changes.append(.init(actionID: id, write: target.value))
                } else if owned {
                    changes.append(.init(actionID: id, write: nil))
                }
            }
            return (changes, kept)
        }

        static func active(in bindings: [String: JSONValue]) -> Preset? {
            for preset in allCases where preset != .cmux {
                let applied = preset.overrides.contains {
                    bindings[$0.key].flatMap(ShortcutBindingFormat.parse) == ShortcutBindingFormat.parse($0.value)
                }
                if applied, preset.plan(from: bindings).changes.isEmpty { return preset }
            }
            return cmux.plan(from: bindings).changes.isEmpty ? .cmux : nil
        }
    }

    enum Digit: String, CaseIterable {
        case tabs, spaces

        var overrides: KeyValuePairs<String, JSONValue> {
            self == .tabs ? [:] : ["space.selectByNumber": "ctrl+1", "selectSurfaceByNumber": "ctrl+opt+1"]
        }

        static let actionIDs = ["space.selectByNumber", "selectSurfaceByNumber"]
        static let catalogDefaults: [String: JSONValue] = ["space.selectByNumber": "ctrl+opt+1", "selectSurfaceByNumber": "ctrl+1"]

        func binding(for id: String) -> ShortcutBinding? {
            (overrides.first { $0.key == id }?.value ?? Self.catalogDefaults[id]).flatMap(ShortcutBindingFormat.parse)
        }

        func plan(from bindings: [String: JSONValue]) -> (changes: [ShortcutKeymapPlan.Change], kept: [String]) {
            var changes: [ShortcutKeymapPlan.Change] = []
            var kept: [String] = []
            for id in Self.actionIDs {
                let current = bindings[id].flatMap(ShortcutBindingFormat.parse)
                guard (current ?? Self.catalogDefaults[id].flatMap(ShortcutBindingFormat.parse)) != binding(for: id) else { continue }
                let owns = current.map { current in Self.allCases.contains { $0.binding(for: id) == current } } ?? false
                guard bindings[id] == nil || owns else { kept.append(id); continue }
                changes.append(.init(actionID: id, write: overrides.first { $0.key == id }?.value))
            }
            return (changes, kept)
        }

        static func active(in bindings: [String: JSONValue]) -> Digit? {
            allCases.first { let plan = $0.plan(from: bindings); return plan.changes.isEmpty && plan.kept.isEmpty }
        }
    }

    static func classicBinding(stored data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = stroke(object, key: "key", prefix: nil) else { return nil }
        var members: [String: JSONValue] = ["first": first]
        if let chordKey = object["chordKey"] as? String, !chordKey.isEmpty {
            guard let second = stroke(object, key: "chordKey", prefix: "chord") else { return nil }
            members["second"] = second
        }
        let binding = JSONValue.object(members)
        return ShortcutBindingFormat.parse(binding) == nil ? nil : binding
    }

    private static func stroke(_ object: [String: Any], key: String, prefix: String?) -> JSONValue? {
        guard let rawKey = object[key] as? String,
              rawKey.count <= 1 || ShortcutBindingFormat.keyEquivalent(forToken: rawKey) != nil else { return nil }
        var stroke: [String: JSONValue] = ["key": .string(rawKey)]
        for modifier in ["command", "shift", "option", "control"] {
            let name = prefix.map { $0 + modifier.prefix(1).uppercased() + modifier.dropFirst() } ?? modifier
            stroke[modifier] = .bool(object[name] as? Bool ?? false)
        }
        return .object(stroke)
    }

    static func importEdits(_ value: JSONValue) throws -> [Edit] {
        guard case .object(var root) = value else { throw SettingsRust.Failure(status: -1) }
        var edits: [Edit] = []
        if case .object(let app)? = root.removeValue(forKey: "app") {
            for key in ["keyStyle", "shortcutLayout"] { if let value = app[key] { edits.append(Edit(path: ["app", key], value: value)) } }
        }
        let shortcuts: [String: JSONValue]
        if case .object(let nested)? = root["shortcuts"] {
            shortcuts = nested
        } else if root.keys.contains(where: { ["bindings", "tiers", "when"].contains($0) }) {
            shortcuts = root
        } else if root.isEmpty {
            shortcuts = [:]
        } else {
            shortcuts = ["bindings": .object(root)]
        }
        return edits + shortcuts.map { Edit(path: ["shortcuts", $0.key], value: $0.value) }
    }

    static func bindings(_ shortcuts: JSONValue) -> [String: JSONValue] {
        guard case .object(let section) = shortcuts else { return [:] }
        var bindings = section.filter { !CmuxConfigSnapshot.reservedShortcutKeys.contains($0.key) }
        if case .object(let entries)? = section["bindings"] { bindings.merge(entries) { _, binding in binding } }
        return bindings
    }
}
