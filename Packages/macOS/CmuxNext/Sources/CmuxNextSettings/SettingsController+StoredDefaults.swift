public import Foundation
import os

/// Stored copies of defaults. Until 2026-11-08 a write of a row's default stored it (a Settings page
/// pick of the value a row already showed), so the key kept that value when a release changed the
/// default: the pane divider #37547 made the default stayed off for anyone whose file held
/// `appearance.chromeStyle: "flat-sidebar-line"`. `setSetting` now removes such a key; this one-time
/// launch pass drops the copies already stored (Leo 2026-11-08: "if I'm on the defaults and the
/// defaults get changed, that should reflect into stuff").
public nonisolated struct StoredDefaultsReport: Sendable, Equatable {
    /// Keys dropped, with the value each held: the current default, or a former one
    /// (`SettingsSchema.formerDefaults`).
    public var dropped: [String: JSONValue] = [:]
    /// Keys kept: a value that was never a default, which the file does not say who wrote, so it
    /// stays as the person's own (the theme and the background among them).
    public var kept: [String: JSONValue] = [:]
}

extension SettingsController {
    /// The launch's settings migrations, in order, each once its own way; a failed one leaves the
    /// file as it was and the next still runs.
    public func runLaunchMigrations(marker: UserDefaults) async {
        // `app.quitBehavior: "end"` (first release) is now "end-keep-layout"; "ask" (the removed quit alert) goes.
        _ = try? await migrateLegacyQuitBehavior()
        // `sidebar.textSize: "default"` / `"larger"` (the first three sizes) are now "small" / "medium".
        _ = try? await migrateLegacySidebarTextSize()
        _ = try? await migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
        _ = try? await migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
        // Classic cmux keys next reads under another name (`ClassicSettingRename`).
        _ = try? await migrateClassicSettings()
        // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
        _ = try? await importClassicShortcuts(marker: marker)
        _ = try? await importClassicPreferences(marker: marker)
        // Last, so a value the steps above moved counts too.
        _ = try? await forgetStoredDefaults(marker: marker)
    }

    /// The UserDefaults key that records the pass ran on this channel (a later pass with other
    /// entries takes its own key, so this one never runs again).
    static let storedDefaultsForgottenKey = "storedDefaultsForgotten.1"

    /// Removes each stored value that is a copy of its key's default, current or former, in one
    /// atomic write, once (`marker` records it). Keys Reset All keeps (the theme, the terminal font),
    /// managed keys and keys a layer below the file fills stay. Before the write it keeps the old
    /// text and both lists beside the file (`cmux-next.json.defaults-forgotten.json`). Returns the
    /// report, or nil when the pass already ran.
    @discardableResult
    public func forgetStoredDefaults(marker: UserDefaults) async throws -> StoredDefaultsReport? {
        try await forgetStoredDefaults(marker: marker, formerDefaults: SettingsSchema.formerDefaults)
    }

    /// `forgetStoredDefaults(marker:)` with the former defaults given (tests change a default).
    @discardableResult
    func forgetStoredDefaults(marker: UserDefaults, formerDefaults: [String: [JSONValue]]) async throws -> StoredDefaultsReport? {
        guard !marker.bool(forKey: Self.storedDefaultsForgottenKey) else { return nil }
        let root = try await file.document()
        var report = StoredDefaultsReport()
        for descriptor in SettingsSchema.all {
            guard let stored = root.value(at: descriptor.path) else { continue }
            let copiesDefault = isUnsetValue(stored, of: descriptor)
                || (formerDefaults[descriptor.id]?.contains(stored) == true && !layerBelowFileSets(descriptor.id))
            if copiesDefault, managedKeys[descriptor.id] == nil, !SettingsSchema.keptOnResetAll.contains(descriptor.path) {
                report.dropped[descriptor.id] = stored
            } else {
                report.kept[descriptor.id] = stored
            }
        }
        if !report.dropped.isEmpty {
            let record: JSONValue = .object([
                "note": .string("cmux dropped these stored copies of defaults once, so each key follows its default again. "
                    + "To keep one, set it again in Settings or copy it back from `before`."),
                "dropped": .object(report.dropped),
                "kept": .object(report.kept),
                "before": .string(try await file.source()),
            ])
            try await file.writeBeside(suffix: "defaults-forgotten.json", text: record.prettyText() + "\n")
            let paths = SettingsSchema.all.filter { report.dropped[$0.id] != nil }.map(\.path)
            try await file.apply(paths.map { (path: $0, value: nil) })
            // Deepest first, so an object a removal empties goes before its parent is checked.
            for parent in Set(paths.flatMap { path in (1..<path.count).map { Array(path.prefix($0)) } })
                .sorted(by: { $0.count > $1.count }) {
                try await pruneEmpty(parent)
            }
            await reloadAfterWrite()
        }
        let dropped = report.dropped.keys.sorted().joined(separator: ", "), kept = report.kept.keys.sorted().joined(separator: ", ")
        Logger(subsystem: "com.cmuxterm.app.next", category: "settings").info(
            "stored defaults: dropped [\(dropped, privacy: .public)]; kept [\(kept, privacy: .public)]")
        marker.set(true, forKey: Self.storedDefaultsForgottenKey)
        return report
    }
}
