import CmuxNextDesign
public import CmuxNextWakeups
public import Foundation

/// The four settings migrations as pure transforms of cmux-next.json (p08-startup-106): each step reads the
/// document and returns the edits it makes, never a file call. Every load applies them to the text it read
/// (``SettingsController/loaded(_:managed:team:lastGood:valid:configDirectory:)``, the launch read included), so the
/// first snapshot already has the migrated keys and no later load shows the legacy ones again; the file gets
/// the same edits once, after startup (``SettingsController/postLaunchMigrationWrites(on:work:classicMarker:)``).
///
/// Chrome migrates obsolete prefs right after the profile's prefs load, before any reader sees them, and the
/// pref store writes them back later (chrome/browser/prefs/browser_prefs.cc, `MigrateObsoleteProfilePrefs`;
/// components/prefs/json_pref_store.cc, `ImportantFileWriter`).
///
/// The steps run in this order, each on what the one before left, as the launch ran them one after another:
/// `sidebar.showWorkspaceDirectory` moves before classic's `sidebar.showBranchDirectory` can claim the same key.
nonisolated enum SettingsLaunchMigration: CaseIterable, Sendable {
    /// `app.quitBehavior: "end"` (first release) becomes "end-keep-layout".
    case quitBehavior
    /// `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`.
    case workspaceRowKeys
    /// `tabs.hiddenButtons` becomes `tabs.toolbarButtons`.
    case paneToolbarButtons
    /// Classic cmux keys next reads under another name (``ClassicSettingRename``).
    case classicSettings

    typealias Edit = (path: [String], value: JSONValue?)

    /// The edits this step makes to `root` (nil value: remove); empty when it has nothing to move.
    ///
    /// - Parameters:
    ///   - root: The user's document (cmux-next.json, parsed).
    ///   - managedKeys: The keys a managed layer sets (dotted key -> manager).
    func edits(in root: JSONValue, managedKeys: [String: ManagedSource]) -> [Edit] {
        switch self {
        case .quitBehavior: Self.quitBehaviorEdits(root)
        case .workspaceRowKeys: Self.workspaceRowEdits(root)
        case .paneToolbarButtons: Self.paneToolbarEdits(root, managedKeys: managedKeys)
        case .classicSettings: Self.classicEdits(root)
        }
    }

    /// `source` with every step applied, or nil when no step changes it.
    ///
    /// A step applies whole or not at all: one whose edit touches a managed key, or whose edit the text
    /// refuses, is left out, as its file write would have failed.
    ///
    /// - Parameters:
    ///   - source: The file's text.
    ///   - root: `source` parsed (an object).
    ///   - managedKeys: The keys a managed layer sets (dotted key -> manager).
    /// - Returns: The migrated text and its parsed document.
    static func migrated(_ source: String, root: JSONValue,
                         managedKeys: [String: ManagedSource]) -> (source: String, root: JSONValue)? {
        var text = source, document = root
        for step in allCases {
            let edits = step.edits(in: document, managedKeys: managedKeys)
            guard !edits.isEmpty, let next = try? applying(edits, to: text, checkedBy: ManagedKeyGuard(managedKeys)),
                  let parsed = try? JSONC.parse(next) else { continue }
            text = next
            document = parsed
        }
        guard text != source else { return nil }
        return (source: text, root: document)
    }

    /// `edits` applied to `source` in order, as ``CmuxConfigFile/apply(_:)`` writes them.
    static func applying(_ edits: [Edit], to source: String, checkedBy managed: ManagedKeyGuard) throws -> String {
        for edit in edits {
            if let value = edit.value { try managed.checkSet(value, at: edit.path) } else { try managed.checkRemove(edit.path) }
        }
        var updated = source
        for edit in edits {
            if let value = edit.value {
                updated = try JSONC.setting(value, at: edit.path, in: updated)
            } else {
                updated = try JSONC.removing(edit.path, in: updated)
            }
        }
        return updated
    }

    // MARK: Steps

    private static func quitBehaviorEdits(_ root: JSONValue) -> [Edit] {
        guard root.value(at: QuitBehaviorSetting.configPath)?.stringValue == QuitBehaviorSetting.legacyEnd else { return [] }
        return [(QuitBehaviorSetting.configPath, .string(QuitBehavior.endKeepLayout.rawValue))]
    }

    /// A set new key wins and the S1 key is dropped; a bad S1 value stays (with its diagnostic) until the user
    /// fixes it or writes the new toggle.
    private static func workspaceRowEdits(_ root: JSONValue) -> [Edit] {
        var edits: [Edit] = []
        for element in WorkspaceRowElement.allCases {
            guard let legacy = WorkspaceRowSetting.legacyPaths[element], let old = root.value(at: legacy) else { continue }
            let path = WorkspaceRowSetting.path(element)
            if root.value(at: path) == nil {
                guard let on = old.boolValue else { continue }
                edits.append((path, .bool(on)))
            }
            edits.append((legacy, nil))
        }
        return edits
    }

    /// The buttons the old row showed become the pinned list (a set new key wins), and the old key goes. A
    /// managed `tabs.toolbarButtons` gets no edit (the old key still goes); an emptied `tabs` is pruned.
    private static func paneToolbarEdits(_ root: JSONValue, managedKeys: [String: ManagedSource]) -> [Edit] {
        let legacy = PaneToolbarButtonsSetting.legacyHiddenPath, path = PaneToolbarButtonsSetting.configPath
        guard let old = root.value(at: legacy) else { return [] }
        if managedKeys[path.joined(separator: ".")] == nil, root.value(at: path) == nil, case .array(let items) = old,
           let value = PaneToolbarButtonsSetting.migrated(hidden: items.compactMap(\.stringValue)).configValue {
            return [(legacy, nil), (path, value)]
        }
        return removingPruned(legacy, in: root)
    }

    /// A value next's descriptor accepts is written and the classic key dropped; a next key already set wins
    /// and the classic key is dropped; a classic value next can't express stays.
    private static func classicEdits(_ root: JSONValue) -> [Edit] {
        var edits: [Edit] = []
        for entry in ClassicSettingRename.entries {
            guard let old = root.value(at: entry.classic) else { continue }
            if root.value(at: entry.next) == nil {
                guard let value = entry.transform(old),
                      SettingsSchema.all.first(where: { $0.path == entry.next })?.accepts(value) == true else { continue }
                edits.append((entry.next, value))
            }
            edits.append((entry.classic, nil))
        }
        return edits
    }

    /// Removes `path`, then each parent object that its removal empties.
    private static func removingPruned(_ path: [String], in root: JSONValue) -> [Edit] {
        var edits: [Edit] = [(path, nil)]
        var removed = path
        while removed.count > 1 {
            let parent = Array(removed.dropLast())
            guard let members = root.value(at: parent)?.objectValue,
                  members.keys.allSatisfy({ $0 == removed[removed.count - 1] }) else { break }
            edits.append((parent, nil))
            removed = parent
        }
        return edits
    }
}

extension ManagedKeyGuard {
    /// A guard over `managedKeys` (dotted key -> manager), as a load leaves the file's.
    convenience init(_ managedKeys: [String: ManagedSource]) {
        self.init()
        update(managedKeys)
    }
}

extension CmuxConfigFile {
    /// Runs `step` on the file as it is now and writes its edits in one atomic publish. Returns whether the
    /// step had edits; throws, writing nothing, when the file is unreadable or an edit touches a managed key.
    func migrate(_ step: SettingsLaunchMigration) throws -> Bool {
        let root = try document()
        let edits = step.edits(in: root, managedKeys: managedGuard.managedKeys)
        guard !edits.isEmpty else { return false }
        try apply(edits)
        return true
    }
}

extension SettingsController {
    /// Posts the launch's settings writes after startup, in one `.bestEffort` task: the migrations every load
    /// already applies are written to the file (each step on the file as it then is), then classic cmux's
    /// shortcuts and preferences are imported (``ClassicShortcutImport``, ``ClassicPreferenceImport``). Nothing on
    /// the first frame's path reads them from the file.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler; the post is its `Settings.launchMigrations` afterStartup task.
    ///   - work: The lanes the task runs on.
    ///   - classicMarker: The defaults that record the classic imports (the app: `.standard`); nil imports nothing.
    public func postLaunchMigrationWrites(on startup: StartupScheduler, work: BackgroundWork,
                                          classicMarker: (@MainActor @Sendable () -> UserDefaults)?) {
        startup.post(.afterStartup, "Settings.launchMigrations", on: .main) { [weak self] in
            guard let self else { return }
            // task-owner: one write of the launch migrations and the two classic imports; quit may skip it, the
            // next launch's load applies the migrations again. R-hop: the file writes run on its actor, off main.
            work.task(.bestEffort) { [weak self] in await self?.writeLaunchMigrations(classicMarker: classicMarker) }
        }
    }

    /// Writes every ``SettingsLaunchMigration`` step that has edits, then runs the classic imports. A step that
    /// fails (a broken file, a managed key) writes nothing and the next one still runs. Returns whether a step wrote.
    @discardableResult
    func writeLaunchMigrations(classicMarker: (@MainActor @Sendable () -> UserDefaults)?) async -> Bool {
        var wrote = false
        for step in SettingsLaunchMigration.allCases {
            if (try? await file.migrate(step)) == true { wrote = true }
        }
        if wrote { await reloadAfterWrite() }
        if let marker = classicMarker?() {
            _ = try? await importClassicShortcuts(marker: marker)
            _ = try? await importClassicPreferences(marker: marker)
        }
        return wrote
    }
}
