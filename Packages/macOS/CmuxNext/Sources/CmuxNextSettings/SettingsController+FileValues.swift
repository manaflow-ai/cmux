public import Foundation

/// The settings file's own values at some paths, present or absent, as one moment read them: what a
/// "put it all back" (the first run's Skip) writes again so the file is as it was.
public nonisolated struct SettingsFileValues: Sendable, Equatable {
    /// Each path's value then; nil: the key was absent.
    public let values: [[String]: JSONValue]
    /// The paths read, absent ones included.
    public let paths: [[String]]
    /// Each parent object of `paths` that existed then: a restore removes only the parents it did not.
    let presentParents: Set<[String]>
}

extension SettingsController {
    /// Every path a ``setSettings(_:by:)`` of `paths` may write: each path, its renamed old key and
    /// the linked edits its write can carry (the window background pair, Plain Backgrounds, the
    /// custom density a built-in ends, the theme file's exceptions).
    public nonisolated static func pathsWritten(by paths: [[String]]) -> [[String]] {
        var out: [[String]] = []
        func add(_ path: [String]) { if !out.contains(path) { out.append(path) } }
        for path in paths {
            add(path)
            for legacy in RenamedSettingKeys.legacyPaths(for: path) { add(legacy) }
            if path == DensitySetting.configPath { add(CustomDensitySelectionSetting.configPath) }
            if path == WindowBackgroundSetting.opacityPath || path == WindowBackgroundSetting.materialPath {
                add(WindowBackgroundSetting.opacityPath)
                add(WindowBackgroundSetting.materialPath)
                add(ReducedBackgroundsSetting.configPath)
            }
        }
        if !paths.isEmpty { add(ThemeFileExceptionsSetting.configPath) }
        return out
    }

    /// The settings file's values at `paths` now (absent ones too), for ``restore(_:)``.
    public func fileValues(at paths: [[String]]) async throws -> SettingsFileValues {
        let root = try await file.document()
        var values: [[String]: JSONValue] = [:]
        var parents: Set<[String]> = []
        for path in paths {
            if let value = root.value(at: path) { values[path] = value }
            for length in 1..<max(path.count, 1) where root.value(at: Array(path.prefix(length))) != nil {
                parents.insert(Array(path.prefix(length)))
            }
        }
        return SettingsFileValues(values: values, paths: paths, presentParents: parents)
    }

    /// Writes `saved` back in one publish: each path that differs now gets its value then exactly
    /// (`set_exact`, no default folding), or goes when it was absent, with the parent objects it
    /// leaves empty that did not exist then. Nothing differs: nothing is written. Returns whether it
    /// wrote.
    @discardableResult
    public func restore(_ saved: SettingsFileValues) async throws -> Bool {
        let root = try await file.document()
        var edits: [SettingsFileEdit] = []
        var prune: [[String]] = []
        for path in saved.paths {
            let then = saved.values[path]
            guard root.value(at: path) != then else { continue }
            if let then {
                edits.append(.set(path, then))
            } else {
                edits.append(.reset(path))
                for length in (1..<max(path.count, 1)).reversed() {
                    let parent = Array(path.prefix(length))
                    if !saved.presentParents.contains(parent), !prune.contains(parent) { prune.append(parent) }
                }
            }
        }
        guard !edits.isEmpty else { return false }
        // Deepest first, each only while it is still empty.
        edits += prune.sorted { $0.count > $1.count }.map { .resetUnchanged($0, .object([:])) }
        try await file.edit(edits)
        await reloadAfterWrite()
        return true
    }
}
