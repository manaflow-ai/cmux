import Foundation

/// Diff viewer layout resolution and the globally persisted viewer display
/// preferences the app writes through its `viewerPrefs` bridge
/// (`~/Library/Application Support/cmux/diff-viewer/preferences.json`).
///
/// The CLI reads that file when generating a viewer page so new diff panels
/// open with the last-used layout and options-menu toggles (#5284). The app's
/// `DiffViewerPreferencesStore` owns the write side and the same sanitizer.
extension CMUXCLI {
    static let diffViewerPreferencesPathEnvironmentKey = "CMUX_DIFF_VIEWER_PREFS_PATH"
    private static let validDiffViewerLayouts: Set<String> = ["split", "unified"]
    private static let validDiffViewerIndicators: Set<String> = ["bars", "classic", "none"]
    private static let diffViewerBooleanPreferenceKeys = [
        "wordWrap", "wordDiffs", "lineNumbers", "showBackgrounds", "expandUnchanged",
    ]

    func resolveDiffViewerLayout(rawLayout: String?) throws -> (layout: String, source: String) {
        if let rawLayout {
            return (try parseDiffViewerLayout(rawLayout, errorMessage: "--layout must be split|unified"), "explicit")
        }
        // The user's last in-viewer layout choice wins over the settings-file
        // default so new diff panels open the way the user last left one.
        if let persisted = persistedDiffViewerPreferences()["layout"] as? String {
            return (persisted, "default")
        }
        return (diffViewerDefaultLayoutSetting() ?? "unified", "default")
    }

    func parseDiffViewerLayout(_ rawValue: String, errorMessage: String) throws -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.validDiffViewerLayouts.contains(normalized) else {
            throw CLIError(message: errorMessage)
        }
        return normalized
    }

    /// The persisted display toggles (everything except `layout`, which the
    /// page receives through `layout`/`layoutSource`) for the page payload.
    func persistedDiffViewerOptionsPayload() -> [String: Any] {
        persistedDiffViewerPreferences().filter { $0.key != "layout" }
    }

    /// Reads the persisted viewer preferences, sanitized to known keys and
    /// values. Returns an empty dictionary when the file is missing or
    /// unreadable. `CMUX_DIFF_VIEWER_PREFS_PATH` overrides the location.
    func persistedDiffViewerPreferences(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: Any] {
        guard let fileURL = Self.diffViewerPreferencesFileURL(environment: environment),
              let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return Self.sanitizeDiffViewerPreferences(object)
    }

    static func diffViewerPreferencesFileURL(environment: [String: String]) -> URL? {
        if let override = environment[diffViewerPreferencesPathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
            .appendingPathComponent("preferences.json", isDirectory: false)
    }

    static func sanitizeDiffViewerPreferences(_ raw: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        if let layout = raw["layout"] as? String, validDiffViewerLayouts.contains(layout) {
            sanitized["layout"] = layout
        }
        if let indicators = raw["diffIndicators"] as? String, validDiffViewerIndicators.contains(indicators) {
            sanitized["diffIndicators"] = indicators
        }
        for key in diffViewerBooleanPreferenceKeys {
            if let value = raw[key] as? Bool {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    private func diffViewerDefaultLayoutSetting() -> String? {
        for path in diffViewerDefaultSettingsPaths() {
            guard let root = diffViewerSettingsRoot(at: path),
                  let section = root["diffViewer"] as? [String: Any],
                  let rawLayout = section["defaultLayout"] as? String,
                  let layout = try? parseDiffViewerLayout(
                      rawLayout,
                      errorMessage: "diffViewer.defaultLayout must be split|unified"
                  ) else {
                continue
            }
            return layout
        }
        return nil
    }

    private func diffViewerDefaultSettingsPaths() -> [String] {
        [
            Self.primarySettingsDisplayPath,
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteDiffViewerSettingsPath)
    }

    private func diffViewerSettingsRoot(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] else {
            return nil
        }
        return root
    }

    /// Upper bound on untracked files appended to an unstaged patch, matching
    /// the Rust sidecar; later paths are left out rather than spawning one git
    /// process per file in an unignored build tree.
    static let maxUnstagedUntrackedPatchPaths = 512

    /// The unstaged working-tree patch: `git diff` plus an added-file patch per
    /// untracked (non-ignored) path. Plain `git diff` omits untracked files,
    /// which silently hid files an agent had just created from the default
    /// review view. The typed sidecar session applies the same rule.
    func gitUnstagedPatchIncludingUntracked(in repoRoot: String) throws -> String {
        try joinedGitDiffPatches(
            [gitStdout(gitDiffPatchArguments(["--"]), in: repoRoot)]
                + gitUntrackedPaths(in: repoRoot).prefix(Self.maxUnstagedUntrackedPatchPaths).map { path in
                    try gitAddedUntrackedPatch(path: path, in: repoRoot)
                }
        )
    }
}
