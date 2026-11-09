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

extension SettingsSchema {
    /// Keys (or, ending in ".", key prefixes) whose readers fill an unset key with something other
    /// than the row's default, which the controller cannot see, with that reader. A written default
    /// stays stored for these (it is the person's override), and the launch pass keeps such copies.
    nonisolated static let unsetIsNotDefaultKeys: [String: String] = [
        // `editor.importFrom` (FilePageLook), `LANGUAGE_DEFAULTS` in webviews' `settingsForLanguage`
        // (Markdown and commit messages wrap, Go and Makefiles indent with tabs), and keys that
        // follow another (`autoClosingQuotes` follows `autoClosingBrackets`).
        // `editor.importFrom` itself is none of these (`unsetIsNotDefault` leaves it out).
        "editor.": "another editor's settings, the built-in per-language values, a key it follows",
        // webviews' `resolveHarnessPlacement`: the Debug tunable `agent.harnessPlacement` fills it.
        "agentPane.display.harnessPlacement": "the Debug tunable agent.harnessPlacement",
    ]

    /// Whether `unsetIsNotDefaultKeys` names `key`.
    nonisolated static func unsetIsNotDefault(_ key: String) -> Bool {
        key != EditorSettingsSchema.importFromPath.joined(separator: ".")
            && unsetIsNotDefaultKeys.keys.contains { $0.hasSuffix(".") ? key.hasPrefix($0) : key == $0 }
    }
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
        _ = try? await dropStrayNulls(marker: marker)
    }

    /// The UserDefaults key that records the pass ran on this channel (a later pass with other
    /// entries takes its own key, so this one never runs again).
    static let storedDefaultsForgottenKey = "storedDefaultsForgotten.1"

    /// The record the pass keeps beside the file (`cmux-next.json.defaults-forgotten.json`). It is
    /// also the per-file mark that the pass ran: the file is shared by every build on the Mac.
    static let storedDefaultsForgottenRecordSuffix = "defaults-forgotten.json"

    /// Removes each stored value that is a copy of its key's default, current or former, in one
    /// atomic write, once per file: `marker` records it for this build and the record beside the
    /// file (`cmux-next.json.defaults-forgotten.json`, written whether or not anything went) for
    /// every other build on the same file. cmux-next.json is shared by NIGHTLY, RC and every tagged
    /// DEV build, each with its own UserDefaults; with only `marker`, each fresh DEV build dropped
    /// the person's later picks of a former default again (`updates.downloadAutomatically: true`,
    /// which flipped the running NIGHTLY's automatic downloads to deferred). Keys Reset All keeps
    /// (the theme, the terminal font), managed keys and keys a layer below the file fills stay.
    /// Before the write it keeps the old text and both lists in the record. Returns the report, or
    /// nil when the pass already ran for this build or this file.
    @discardableResult
    public func forgetStoredDefaults(marker: UserDefaults) async throws -> StoredDefaultsReport? {
        try await forgetStoredDefaults(marker: marker, formerDefaults: SettingsSchema.formerDefaults)
    }

    /// `forgetStoredDefaults(marker:)` with the former defaults given (tests change a default).
    @discardableResult
    func forgetStoredDefaults(marker: UserDefaults, formerDefaults: [String: [JSONValue]]) async throws -> StoredDefaultsReport? {
        guard !marker.bool(forKey: Self.storedDefaultsForgottenKey) else { return nil }
        if await file.hasRecordBeside(suffix: Self.storedDefaultsForgottenRecordSuffix) {
            marker.set(true, forKey: Self.storedDefaultsForgottenKey)
            return nil
        }
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
            // Rechecked at the write: a key someone set since the read above stays, and counts as
            // kept. The record goes beside the file before the publish, so nothing is removed
            // without it.
            let candidates = SettingsSchema.all.compactMap { descriptor in report.dropped[descriptor.id].map { (descriptor, $0) } }
            let read = report
            let (removed, before) = try await removeUnchanged(
                candidates.map { (path: $0.0.path, value: $0.1) }, recordBeside: Self.storedDefaultsForgottenRecordSuffix
            ) { removed, before in
                Self.storedDefaultsRecord(Self.settled(read, candidates: candidates, removed: removed, before: before), before: before)
            }
            report = Self.settled(report, candidates: candidates, removed: removed, before: before)
        }
        if !(await file.hasRecordBeside(suffix: Self.storedDefaultsForgottenRecordSuffix)) {
            // Nothing went (or the removal found every value changed): the record still marks the file.
            try await file.writeBeside(suffix: Self.storedDefaultsForgottenRecordSuffix,
                                       text: Self.storedDefaultsRecord(report, before: try await file.source()))
        }
        let dropped = report.dropped.keys.sorted().joined(separator: ", "), kept = report.kept.keys.sorted().joined(separator: ", ")
        Logger(subsystem: "com.cmuxterm.app.next", category: "settings").info(
            "stored defaults: dropped [\(dropped, privacy: .public)]; kept [\(kept, privacy: .public)]")
        marker.set(true, forKey: Self.storedDefaultsForgottenKey)
        return report
    }

    /// The record's text: what went, what stayed and the file's text before the pass.
    nonisolated static func storedDefaultsRecord(_ report: StoredDefaultsReport, before: String) -> String {
        let record: JSONValue = .object([
            "note": .string("cmux dropped these stored copies of defaults once, so each key follows its default again. "
                + "To keep one, set it again in Settings or copy it back from `before`."),
            "dropped": .object(report.dropped),
            "kept": .object(report.kept),
            "before": .string(before),
        ])
        return record.prettyText() + "\n"
    }

    /// `report` once the write removed only `removed`: each other candidate is kept, with its value
    /// in `before` (the file at the write).
    nonisolated static func settled(_ report: StoredDefaultsReport, candidates: [(SettingDescriptor, JSONValue)],
                                    removed: [[String]], before: String) -> StoredDefaultsReport {
        var report = report
        let root = try? JSONC.parse(before)
        for (descriptor, read) in candidates where !removed.contains(descriptor.path) {
            report.dropped[descriptor.id] = nil
            report.kept[descriptor.id] = root?.value(at: descriptor.path) ?? read
        }
        return report
    }

    /// The UserDefaults key that records `dropStrayNulls` ran on this channel.
    static let strayNullsDroppedKey = "settingsStrayNullsDropped.1"

    /// Removes, once (`marker` records it), each schema key whose stored value is JSON null, that
    /// refuses null and whose null the last load reported invalid. #38119's first builds stored null
    /// for a write of a default (a `nil` literal typed as `JSONValue` is `.null`); it loads as the
    /// default, with that diagnostic. A null a parser takes on purpose (`notifications.quietHours:
    /// null` is Off) has none and stays. Returns the keys.
    @discardableResult
    public func dropStrayNulls(marker: UserDefaults) async throws -> [String] {
        guard !marker.bool(forKey: Self.strayNullsDroppedKey) else { return [] }
        let root = try await file.document()
        let invalid = Set(diagnostics.filter { $0.kind == .invalidValue && $0.file == nil }.map(\.path))
        let stray = SettingsSchema.all.filter {
            root.value(at: $0.path) == .null && !$0.accepts(.null) && invalid.contains($0.id) && managedKeys[$0.id] == nil
        }
        // Rechecked at the write: a key someone set since the read above stays.
        let removed = stray.isEmpty ? [] : try await removeUnchanged(stray.map { (path: $0.path, value: JSONValue.null) }).removed
        marker.set(true, forKey: Self.strayNullsDroppedKey)
        return stray.filter { removed.contains($0.path) }.map(\.id)
    }

    /// `CmuxConfigFile.removeUnchanged`, then a reload when it removed anything.
    private func removeUnchanged(
        _ expected: [(path: [String], value: JSONValue)],
        recordBeside suffix: String? = nil,
        record: @escaping @Sendable ([[String]], String) throws -> String = { _, _ in "" }
    ) async throws -> (removed: [[String]], before: String) {
        let result = try await file.removeUnchanged(expected, recordBeside: suffix, record: record)
        if !result.removed.isEmpty { await reloadAfterWrite() }
        return result
    }
}
