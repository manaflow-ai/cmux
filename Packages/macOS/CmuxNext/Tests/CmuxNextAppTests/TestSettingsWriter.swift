import CmuxNextSettings
import Foundation

/// The tests' stand-in for the daemon's settings owner (cmux-tui `cmux-config` `settings.edit`,
/// whose own tests cover the comment-keeping JSONC editor): applies the edits to the parsed file and
/// writes it back as plain JSON, comments dropped. A `reset_unchanged` that applies also drops the
/// objects it empties, as the owner does for a settings row.
nonisolated struct TestSettingsWriter: SettingsFileWriter {
    func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int] {
        let target = file.resolvingSymlinksInPath()
        let before = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let original = try JSONC.parse(before)
        var root = original
        var applied: [Int] = []
        for (index, edit) in edits.enumerated() {
            switch edit {
            case .set(let path, let value):
                root = Self.setting(value, at: path[...], in: root)
            case .setUnset(let path, let value):
                guard root.value(at: path) == nil else { continue }
                root = Self.setting(value, at: path[...], in: root)
            case .reset(let path):
                root = Self.removing(path[...], in: root, pruning: false)
            case .resetUnchanged(let path, let value):
                guard root.value(at: path) == value else { continue }
                root = Self.removing(path[...], in: root, pruning: true)
            }
            applied.append(index)
        }

        if root != original {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((root.prettyText() + "\n").utf8).write(to: target, options: .atomic)
        }
        return applied
    }

    private static func setting(_ value: JSONValue, at path: ArraySlice<String>, in node: JSONValue) -> JSONValue {
        guard let key = path.first else { return value }
        var members: [String: JSONValue] = [:]
        if case .object(let existing) = node { members = existing }
        members[key] = setting(value, at: path.dropFirst(), in: members[key] ?? .object([:]))
        return .object(members)
    }

    private static func removing(_ path: ArraySlice<String>, in node: JSONValue, pruning: Bool) -> JSONValue {
        guard let key = path.first, case .object(var members) = node, let child = members[key] else { return node }
        if path.count == 1 {
            members[key] = nil
        } else {
            let pruned = removing(path.dropFirst(), in: child, pruning: pruning)
            // Not `cond ? nil : pruned`: JSONValue takes a nil literal as `.null`, which keeps the key.
            if pruning, pruned == .object([:]) { members.removeValue(forKey: key) } else { members[key] = pruned }
        }
        return .object(members)
    }
}
