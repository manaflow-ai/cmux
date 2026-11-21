/// The buttons a pane's tab bar shows next to its "…", in cmux.json (Lawrence 2026-10-12; the
/// same shape as `browser.toolbarButtons`):
///
/// ```jsonc
/// "tabs": { "toolbarButtons": ["splitRight", "splitDown"] }
/// ```
///
/// By default the tab bar's trailing end is only "…" (More), which is never in the list. A listed
/// action shows as its own button before "…" while the shown tab can run it; every other action
/// stays a row of "…", whose Show in Tab Bar items pin it back. The buttons and "…" fade in while
/// the pointer is over the tab bar, like its "+". A bad or unknown item is dropped with a
/// diagnostic. The app reads the effective root (``current(_:)``), so the snapshot type does not
/// grow. Replaces `tabs.hiddenButtons` (``SettingsController/migrateLegacyPaneToolbarButtons()``).
public nonisolated struct PaneToolbarButtonsSetting: Sendable, Hashable {
    /// The pinned actions' ids, in the order the user wrote them.
    public var pinned: [String]

    public init(pinned: [String]) {
        self.pinned = pinned
    }

    /// The list in cmux.json's root; a missing list is the default.
    public static func read(_ root: JSONValue) -> PaneToolbarButtonsSetting {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> PaneToolbarButtonsSetting {
        guard let value = root.value(at: configPath) else { return PaneToolbarButtonsSetting(pinned: fallback) }
        let id = configPath.joined(separator: ".")
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an array of action ids"))
            return PaneToolbarButtonsSetting(pinned: fallback)
        }
        let known = items.compactMap(\.stringValue).filter(values.contains)
        if known.count != items.count {
            let list = values.map { "\"\($0)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected action ids: \(list)"))
        }
        // The user's order; a repeated id keeps its first place.
        var ids: [String] = []
        for item in known where !ids.contains(item) { ids.append(item) }
        if ids.count != known.count {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "an action id is listed more than once"))
        }
        return PaneToolbarButtonsSetting(pinned: ids)
    }

    /// The list with `id` pinned at the end, or unpinned in place.
    public func toggling(_ id: String) -> PaneToolbarButtonsSetting {
        PaneToolbarButtonsSetting(pinned: pinned.contains(id) ? pinned.filter { $0 != id } : pinned + [id])
    }

    /// The value to write: nil (remove the key) when it is the default.
    public var configValue: JSONValue? {
        pinned == Self.fallback ? nil : .array(pinned.map(JSONValue.string))
    }

    // MARK: tabs.hiddenButtons

    /// The key this list replaced: the buttons right-clicked away from the old row (cx-kk7lm).
    public static let legacyHiddenPath = ["tabs", "hiddenButtons"]

    /// The old row's buttons for `hidden`: the first four of a terminal's actions not hidden.
    static func migrated(hidden: [String]) -> PaneToolbarButtonsSetting {
        let row = ["splitRight", "splitDown", "openDiffViewer", "file.open", "toggleSplitZoom"].filter { !hidden.contains($0) }
        return PaneToolbarButtonsSetting(pinned: Array(row.prefix(4)))
    }
}

extension PaneToolbarButtonsSetting {
    /// The pinned actions the app applies: the effective root, so a managed value decides.
    @MainActor public static func current(_ settings: SettingsController) -> PaneToolbarButtonsSetting {
        read(settings.snapshot.root)
    }
}

extension SettingsController {
    /// Moves `tabs.hiddenButtons` to `tabs.toolbarButtons` in one atomic write, once at launch:
    /// the buttons the old row showed become the pinned list (a set new key wins), and the old key
    /// goes. Returns whether it wrote.
    /// A managed `tabs.toolbarButtons` gets no edit (the old key still goes); an emptied `tabs` is pruned.
    @discardableResult
    public func migrateLegacyPaneToolbarButtons() async throws -> Bool {
        guard let old = try await file.value(at: PaneToolbarButtonsSetting.legacyHiddenPath) else { return false }
        let path = PaneToolbarButtonsSetting.configPath
        if managedKeys[path.joined(separator: ".")] == nil, try await file.value(at: path) == nil, case .array(let items) = old,
           let value = PaneToolbarButtonsSetting.migrated(hidden: items.compactMap(\.stringValue)).configValue {
            try await file.apply([(PaneToolbarButtonsSetting.legacyHiddenPath, nil), (path, value)])
            await reloadAfterWrite()
        } else {
            try await removePruning(PaneToolbarButtonsSetting.legacyHiddenPath)
        }
        return true
    }
}
