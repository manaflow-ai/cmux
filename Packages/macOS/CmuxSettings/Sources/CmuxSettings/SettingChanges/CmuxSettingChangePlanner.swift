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

    init(schema: CmuxConfigSchemaPathLookup = CmuxConfigSchemaPathLookup()) {
        self.schema = schema
    }

    func edits(for change: CmuxSettingChange, in root: [String: Any]) throws -> [Edit] {
        switch change {
        case .set(let path, let value):
            return [Edit(path: try settingPath(path), value: value.jsonObject)]
        case .unset(let path):
            return [Edit(path: try settingPath(path), value: nil)]
        case .toggle(let rawPath):
            let path = try settingPath(rawPath)
            let current = effectiveValue(at: path, in: root)
            guard let current = current.flatMap(CmuxSettingValue.init(jsonObject:)),
                  case .bool(let flag) = current else {
                throw CmuxSettingChangeError.notBoolean(rawPath)
            }
            return [Edit(path: path, value: NSNumber(value: !flag))]
        case .cycle(let rawPath, let values):
            let path = try settingPath(rawPath)
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
            guard let presets = root[Self.presetsKey] as? [String: Any],
                  let preset = presets[name] else {
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
                edits.append(Edit(path: try settingPath(components), value: value))
            }
        }
    }

    /// Validates a dotted settings path: declared by the schema and outside
    /// the non-setting sections.
    func settingPath(_ raw: String) throws -> JSONPath {
        let components = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return try settingPath(components, display: raw)
    }

    private func settingPath(_ components: [String], display: String? = nil) throws -> JSONPath {
        let display = display ?? components.joined(separator: ".")
        guard !components.isEmpty, !components.contains(where: \.isEmpty) else {
            throw CmuxSettingChangeError.unknownPath(display)
        }
        // A key containing "." can't be addressed by a dotted JSONPath.
        guard !components.contains(where: { $0.contains(".") }) else {
            throw CmuxSettingChangeError.unknownPath(display)
        }
        guard !Self.nonSettingSections.contains(components[0]) else {
            throw CmuxSettingChangeError.notASetting(display)
        }
        guard schema.isDeclared(components) else {
            throw CmuxSettingChangeError.unknownPath(display)
        }
        return JSONPath(dottedPath: components.joined(separator: "."))
    }

    /// The configured value, or the schema default when the file doesn't
    /// set the path.
    private func effectiveValue(at path: JSONPath, in root: [String: Any]) -> Any? {
        path.lookup(in: root) ?? schema.defaultValue(at: path.components)
    }

    func defaultValue(at path: JSONPath) -> Any? {
        schema.defaultValue(at: path.components)
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
