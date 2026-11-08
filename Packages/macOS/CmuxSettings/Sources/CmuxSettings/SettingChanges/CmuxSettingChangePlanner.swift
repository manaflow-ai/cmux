import CmuxFoundation
import Foundation

/// Turns a ``CmuxSettingChange`` into concrete path edits against the current
/// config root. Runs inside ``JSONConfigStore``'s writer lock so `toggle`,
/// `cycle`, and `preset` read the same document they rewrite.
struct CmuxSettingChangePlanner {
    struct Edit {
        let path: JSONPath
        /// The value to write, or nil to remove the path.
        let value: Any?
    }

    /// Top-level sections of cmux.json that hold hand-written structure
    /// rather than settings. A setting change never writes into them; the
    /// `settingPresets` a change reads from is one of them.
    static let nonSettingSections: Set<String> = [
        "$schema",
        "schemaVersion",
        "actions",
        "commands",
        "newWorkspaceCommand",
        "packs",
        "rightSidebar",
        "settingPresets",
        "surfaceTabBarButtons",
        "ui",
        "vault",
    ]

    static let presetsKey = "settingPresets"

    private let schema: CmuxConfigSchemaPathLookup
    private let liveValues: CmuxSettingLiveValues
    private let presetOverrides: [String: CmuxSettingValue]

    init(
        schema: CmuxConfigSchemaPathLookup = CmuxConfigSchemaPathLookup(),
        liveValues: CmuxSettingLiveValues = .schemaDefaultsOnly,
        presetOverrides: [String: CmuxSettingValue] = [:]
    ) {
        self.schema = schema
        self.liveValues = liveValues
        self.presetOverrides = presetOverrides
    }

    func edits(for change: CmuxSettingChange, in root: [String: Any]) throws -> [Edit] {
        switch change {
        case .set(let path, let value):
            return [Edit(path: try settingPath(path, root: root), value: value.jsonObject)]
        case .unset(let path):
            return [Edit(path: try settingPath(path, root: root), value: nil)]
        case .toggle(let rawPath):
            let path = try settingPath(rawPath, root: root)
            let current = effectiveValue(at: path, in: root)
            guard let current = current.flatMap(CmuxSettingValue.init(jsonObject:)),
                  case .bool(let flag) = current else {
                throw CmuxSettingChangeError.notBoolean(rawPath)
            }
            return [Edit(path: path, value: NSNumber(value: !flag))]
        case .cycle(let rawPath, let values):
            let path = try settingPath(rawPath, root: root)
            guard let first = values.first else {
                throw CmuxSettingChangeError.emptyCycle(rawPath)
            }
            let current = effectiveValue(at: path, in: root).flatMap(CmuxSettingValue.init(jsonObject:))
            let next: CmuxSettingValue
            if let current, let index = values.firstIndex(where: { Self.matches($0, current) }) {
                next = values[(index + 1) % values.count]
            } else {
                next = first
            }
            return [Edit(path: path, value: next.jsonObject)]
        case .preset(let name):
            let presetObject = (root[Self.presetsKey] as? [String: Any])?[name]
                ?? presetOverrides[name]?.jsonObject
            guard let preset = presetObject else {
                throw CmuxSettingChangeError.unknownPreset(name)
            }
            guard let settings = preset as? [String: Any], !settings.isEmpty else {
                throw CmuxSettingChangeError.invalidPreset(name)
            }
            if let section = settings.keys.sorted().first(where: Self.nonSettingSections.contains) {
                throw CmuxSettingChangeError.notASetting(section)
            }
            var edits: [Edit] = []
            try appendLeafEdits(of: settings, prefix: [], into: &edits)
            guard !edits.isEmpty else {
                throw CmuxSettingChangeError.invalidPreset(name)
            }
            return edits
        }
    }

    /// Flattens a partial settings object into one edit per leaf so a preset
    /// only replaces the keys it names.
    private func appendLeafEdits(
        of object: [String: Any],
        prefix: [String],
        into edits: inout [Edit]
    ) throws {
        for key in object.keys.sorted() {
            let components = prefix + [key]
            let value = object[key]!
            if let child = value as? [String: Any] {
                // An empty object merges nothing. Writing it as a leaf would
                // replace the whole section, comments included.
                try appendLeafEdits(of: child, prefix: components, into: &edits)
            } else {
                // Re-encode through CmuxSettingValue so a preset's 1.4 is
                // written as 1.4, the same as a `set` or `cycle` value.
                edits.append(Edit(
                    path: try settingPath(components),
                    value: CmuxSettingValue(jsonObject: value)?.jsonObject ?? value
                ))
            }
        }
    }

    /// Validates a dotted settings path: declared by the schema and outside
    /// the non-setting sections. `root` is the current file, used only to
    /// explain a refusal.
    func settingPath(_ raw: String, root: [String: Any] = [:]) throws -> JSONPath {
        let components = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return try settingPath(components, display: raw, root: root)
    }

    private func settingPath(
        _ components: [String],
        display: String? = nil,
        root: [String: Any] = [:]
    ) throws -> JSONPath {
        let display = display ?? components.joined(separator: ".")
        guard !components.isEmpty, !components.contains(where: \.isEmpty) else {
            throw CmuxSettingChangeError.unknownPath(display)
        }
        // A key containing "." (a preset's object key) can't be addressed by
        // a dotted JSONPath.
        guard !components.contains(where: { $0.contains(".") }) else {
            throw CmuxSettingChangeError.keyContainsDot(display)
        }
        guard !Self.nonSettingSections.contains(components[0]) else {
            throw CmuxSettingChangeError.notASetting(display)
        }
        guard schema.isDeclared(components) else {
            if resolvesWithDottedKey(components, root: root) {
                throw CmuxSettingChangeError.keyContainsDot(display)
            }
            throw CmuxSettingChangeError.unknownPath(display)
        }
        return JSONPath(dottedPath: components.joined(separator: "."))
    }

    /// Whether rejoining some adjacent components with "." gives a declared
    /// path whose rejoined key the caller most likely meant: one the file
    /// already has, or a path-like key such as a `workspaceGroups.byCwd`
    /// entry for `~/src/app.web`. A typo under a map keyed by names (for
    /// example `shortcuts.bindings.toggleSidebar.foo`) stays an unknown
    /// path. Used only to explain the refusal; such keys stay unsupported.
    private func resolvesWithDottedKey(_ components: [String], root: [String: Any]) -> Bool {
        // Each bit of `mask` joins component i to component i + 1. Paths are
        // short; the cap keeps a pathological argument cheap.
        let joints = components.count - 1
        guard joints > 0, joints <= 10 else { return false }
        for mask in 1..<(1 << joints) {
            var merged: [String] = [components[0]]
            for index in 1..<components.count {
                if mask & (1 << (index - 1)) != 0 {
                    merged[merged.count - 1] += "." + components[index]
                } else {
                    merged.append(components[index])
                }
            }
            guard !Self.nonSettingSections.contains(merged[0]), schema.isDeclared(merged) else {
                continue
            }
            let rejoined = merged.filter { $0.contains(".") }
            if rejoined.contains(where: { $0.contains("/") })
                || Self.value(at: merged, in: root) != nil {
                return true
            }
        }
        return false
    }

    /// The configured value; when the file doesn't set the path, the live
    /// value (for example from UserDefaults), then the schema default.
    private func effectiveValue(at path: JSONPath, in root: [String: Any]) -> Any? {
        path.lookup(in: root)
            ?? liveValue(at: path)?.jsonObject
            ?? schema.defaultValue(at: path.components)
    }

    func liveValue(at path: JSONPath) -> CmuxSettingValue? {
        liveValues.value(at: path.components.joined(separator: "."))
    }

    func defaultValue(at path: JSONPath) -> Any? {
        schema.defaultValue(at: path.components)
    }

    /// The value at `components`, which may contain keys with "." that a
    /// ``JSONPath`` can't express.
    private static func value(at components: [String], in root: [String: Any]) -> Any? {
        var cursor: Any = root
        for component in components {
            guard let object = cursor as? [String: Any], let next = object[component] else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Cycle membership. Numbers compare with a small tolerance so `1.4`
    /// read back from disk still matches the `1.4` in the action.
    static func matches(_ lhs: CmuxSettingValue, _ rhs: CmuxSettingValue) -> Bool {
        if case .number(let left) = lhs, case .number(let right) = rhs {
            return abs(left - right) <= 1e-9 * max(1, abs(left), abs(right))
        }
        return lhs == rhs
    }
}
