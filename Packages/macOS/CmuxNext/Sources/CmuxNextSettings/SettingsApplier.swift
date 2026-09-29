import AppKit
public import CmuxNextActions
public import CmuxNextDesign

/// Applies a parsed cmux.json snapshot to the live objects on the main
/// actor: `DesignSettings` (density and metric overrides) and the action
/// registry (shortcut overrides). The file is the source of truth, so a key
/// removed from the file reverts to its default on the next apply.
@MainActor
public final class SettingsApplier {
    public let design: DesignSettings
    public let registry: ActionRegistry
    /// Action IDs whose shortcut override came from the file last time, so
    /// removing a binding from the file restores the default.
    private var appliedShortcutIDs: Set<ActionID> = []

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
        for key in MetricKey.allCases {
            let value = snapshot.metrics[key.rawValue].map { CGFloat($0) }
            let range = DesignSettings.allowedRange(key)
            let clamped = value.map { min(max($0, range.lowerBound), range.upperBound) }
            // Skip no-op writes so observers do not re-lay out on every save.
            if design.overrides[key] != clamped { design.setOverride(key, value) }
        }

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
            case .chord:
                diagnostics.append(SettingsDiagnostic(kind: .unsupportedChord, path: path, message: "chords are not supported yet; the default shortcut stays"))
                continue
            }
            applied.insert(id)
        }
        for id in appliedShortcutIDs.subtracting(applied) {
            registry.removeShortcutOverride(for: id)
        }
        appliedShortcutIDs = applied

        diagnostics += Self.conflictDiagnostics(in: registry)
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
