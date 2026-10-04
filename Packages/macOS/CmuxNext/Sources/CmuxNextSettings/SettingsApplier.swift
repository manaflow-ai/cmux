import AppKit
public import CmuxNextActions
public import CmuxNextDesign

/// Applies a parsed cmux.json snapshot to the live objects on the main
/// actor: `DesignSettings` (density, metric overrides and pane chrome) and the action
/// registry (shortcut overrides). The file is the source of truth, so a key
/// removed from the file reverts to its default on the next apply.
@MainActor
public final class SettingsApplier {
    public let design: DesignSettings
    public let registry: ActionRegistry
    /// Action IDs whose shortcut override came from the file last time, so
    /// removing a binding from the file restores the default.
    private var appliedShortcutIDs: Set<ActionID> = []
    /// Same for key routing tiers.
    private var appliedTierIDs: Set<ActionID> = []

    public init(design: DesignSettings = .shared, registry: ActionRegistry) {
        self.design = design
        self.registry = registry
    }

    public static var validDensities: Set<String> { Set(Density.allCases.map(\.rawValue)) }
    public static var validMetrics: Set<String> { Set(MetricKey.allCases.map(\.rawValue)) }

    /// Applies `snapshot` and returns every diagnostic: the parse
    /// diagnostics, unknown action IDs, chords, and shortcut conflicts.
    @discardableResult
    public func apply(_ snapshot: CmuxConfigSnapshot) -> [SettingsDiagnostic] {
        var diagnostics = snapshot.diagnostics
        if diagnostics.contains(where: { $0.kind == .unreadableFile }) {
            // Keep the last good state rather than resetting everything.
            return diagnostics
        }

        let density = snapshot.density.flatMap(Density.init(rawValue:)) ?? .compact
        if design.density != density { design.density = density }
        if design.animationSpeed != snapshot.animationSpeed { design.animationSpeed = snapshot.animationSpeed }
        if design.centerFocusedColumn != snapshot.centerFocusedColumn { design.centerFocusedColumn = snapshot.centerFocusedColumn }
        if design.stripScrollbar != snapshot.stripScrollbar { design.stripScrollbar = snapshot.stripScrollbar }
        if design.sidebarSections != snapshot.sidebarSections { design.sidebarSections = snapshot.sidebarSections }
        if design.splitSizing != snapshot.splitSizing { design.splitSizing = snapshot.splitSizing }
        if design.newColumnWidth != snapshot.newColumnWidth { design.newColumnWidth = snapshot.newColumnWidth }
        if design.stickyColumnEdge != snapshot.stickyColumnEdge { design.stickyColumnEdge = snapshot.stickyColumnEdge }
        if design.stickyColumnMode != snapshot.stickyColumnMode { design.stickyColumnMode = snapshot.stickyColumnMode }
        if design.frameOrientation != snapshot.frameOrientation { design.frameOrientation = snapshot.frameOrientation }
        if design.layoutRows != snapshot.layoutRows { design.layoutRows = snapshot.layoutRows }
        if design.minimumPaneContentSize != snapshot.minimumPaneContentSize { design.minimumPaneContentSize = snapshot.minimumPaneContentSize }
        if design.closeFocus != snapshot.closeFocus { design.closeFocus = snapshot.closeFocus }
        if design.defaultColumnWidth != snapshot.defaultColumnWidth { design.defaultColumnWidth = snapshot.defaultColumnWidth }
        if design.focusRing != snapshot.focusRing { design.focusRing = snapshot.focusRing }
        if design.attention != snapshot.attention { design.attention = snapshot.attention }
        if design.statusIndicator != snapshot.statusIndicator { design.statusIndicator = snapshot.statusIndicator }
        if design.statusBehavior != snapshot.statusBehavior { design.statusBehavior = snapshot.statusBehavior }
        if design.titlebar != snapshot.titlebar { design.titlebar = snapshot.titlebar }
        if design.borders != snapshot.borders { design.borders = snapshot.borders }
        if design.focusIndicator != snapshot.focusIndicator { design.focusIndicator = snapshot.focusIndicator }
        if design.inactiveTabStyle != snapshot.inactiveTabStyle { design.inactiveTabStyle = snapshot.inactiveTabStyle }
        for key in MetricKey.allCases {
            let value = snapshot.metrics[key.rawValue].map { CGFloat($0) }
            let range = DesignSettings.allowedRange(key)
            let clamped = value.map { min(max($0, range.lowerBound), range.upperBound) }
            // Skip no-op writes so observers do not re-lay out on every save.
            if design.overrides[key] != clamped { design.setOverride(key, value) }
        }

        design.setPaneChrome(snapshot.paneChrome)

        var applied: Set<ActionID> = []
        for (rawID, binding) in snapshot.shortcuts.sorted(by: { $0.key < $1.key }) {
            let path = "shortcuts.bindings.\(rawID)"
            let requested = ActionID(rawValue: rawID)
            guard registry.descriptor(for: requested) != nil || registry.isBound(requested) else {
                diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: path, message: "no action with this id"))
                continue
            }
            let id = registry.canonicalID(for: requested)
            switch binding {
            case .unbound:
                setOverride(nil, for: id)
            case .stroke(let stroke):
                setOverride(Self.shortcut(for: stroke), for: id)
            case .chord(let first, let second):
                // Only Command and Control chords reach the key router.
                guard first.command || first.control else {
                    diagnostics.append(SettingsDiagnostic(kind: .unsupportedChord, path: path,
                                                          message: "the first key of a chord needs cmd or ctrl; the default shortcut stays"))
                    continue
                }
                let chord = ShortcutChord(Self.shortcut(for: first), Self.shortcut(for: second))
                if registry.chordOverrides[id] != chord { registry.setChordOverride(chord, for: id) }
            }
            applied.insert(id)
        }
        for id in appliedShortcutIDs.subtracting(applied) {
            registry.removeShortcutOverride(for: id)
        }
        appliedShortcutIDs = applied
        diagnostics += applyKeyTiers(snapshot.keyTiers)

        diagnostics += tabBarDiagnostics(snapshot.tabBar)
        diagnostics += Self.conflictDiagnostics(in: registry)
        return diagnostics
    }

    /// Buttons whose action is neither a cmux.json action nor in the registry.
    private func tabBarDiagnostics(_ tabBar: SurfaceTabBarConfig) -> [SettingsDiagnostic] {
        tabBar.buttons.compactMap { button in
            let id = ActionID(rawValue: button.actionID)
            if button.actionID.hasPrefix(ConfigCommandAction.actionIDPrefix)
                || registry.descriptor(for: id) != nil || registry.isBound(id) { return nil }
            return SettingsDiagnostic(kind: .unknownAction, path: "ui.surfaceTabBar.buttons",
                                      message: "no action '\(button.actionID)' for button '\(button.id)'")
        }
    }

    /// `shortcuts.tiers`: a removed entry restores the catalog tier.
    private func applyKeyTiers(_ tiers: [String: String]) -> [SettingsDiagnostic] {
        var diagnostics: [SettingsDiagnostic] = []
        var applied: Set<ActionID> = []
        for (rawID, value) in tiers.sorted(by: { $0.key < $1.key }) {
            let requested = ActionID(rawValue: rawID)
            guard registry.descriptor(for: requested) != nil || registry.isBound(requested) else {
                diagnostics.append(SettingsDiagnostic(kind: .unknownAction, path: "shortcuts.tiers.\(rawID)", message: "no action with this id"))
                continue
            }
            let id = registry.canonicalID(for: requested)
            let tier = ActionKeyTier(configValue: value)
            if registry.keyTierOverrides[id] != tier { registry.setKeyTierOverride(tier, for: id) }
            applied.insert(id)
        }
        for id in appliedTierIDs.subtracting(applied) { registry.setKeyTierOverride(nil, for: id) }
        appliedTierIDs = applied
        return diagnostics
    }

    private func setOverride(_ shortcut: Shortcut?, for id: ActionID) {
        if let current = registry.shortcutOverrides[id], current == shortcut { return }
        registry.setShortcutOverride(shortcut, for: id)
    }

    /// The registry shortcut for a parsed stroke.
    public static func shortcut(for stroke: ShortcutStrokeSpec) -> Shortcut {
        var modifiers: NSEvent.ModifierFlags = []
        if stroke.command { modifiers.insert(.command) }
        if stroke.shift { modifiers.insert(.shift) }
        if stroke.option { modifiers.insert(.option) }
        if stroke.control { modifiers.insert(.control) }
        return Shortcut(stroke.key, modifiers: modifiers)
    }

    /// The config stroke for a registry shortcut (for writing back).
    public static func stroke(for shortcut: Shortcut) -> ShortcutStrokeSpec {
        ShortcutStrokeSpec(
            key: shortcut.key,
            command: shortcut.modifiers.contains(.command),
            shift: shortcut.modifiers.contains(.shift),
            option: shortcut.modifiers.contains(.option),
            control: shortcut.modifiers.contains(.control)
        )
    }

    /// One diagnostic per group of actions that claim the same shortcut in
    /// the same context.
    public static func conflictDiagnostics(in registry: ActionRegistry) -> [SettingsDiagnostic] {
        registry.shortcutConflicts().map { group in
            let shortcut = registry.shortcutDisplay(for: group[0]) ?? ""
            return SettingsDiagnostic(
                kind: .shortcutConflict,
                path: group.map { "shortcuts.bindings.\($0.rawValue)" }.joined(separator: ", "),
                message: "\(shortcut) is bound to \(group.map(\.rawValue).joined(separator: ", "))"
            )
        }
    }
}
