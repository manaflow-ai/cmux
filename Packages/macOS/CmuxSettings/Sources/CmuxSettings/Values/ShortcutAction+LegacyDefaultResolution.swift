extension ShortcutAction {
    /// Resolves a persisted shortcut while preserving an explicitly configured
    /// binding that predates a built-in default migration.
    ///
    /// - Parameters:
    ///   - candidate: The configured shortcut, or `nil` when no override exists.
    ///   - hostDefault: An optional host-owned default. Pass
    ///     ``StoredShortcut/unbound`` to explicitly disable the built-in value.
    public func effectivePersistedShortcutResolvingLegacyConflicts(
        _ candidate: StoredShortcut?,
        defaultShortcut hostDefault: StoredShortcut? = nil,
        explicitlyConfiguredShortcut: (ShortcutAction) -> StoredShortcut?,
        bindingsConflict: (
            _ proposed: StoredShortcut,
            _ configuredAction: ShortcutAction,
            _ configured: StoredShortcut
        ) -> Bool,
        conflictsWithReservedShortcut: (StoredShortcut) -> Bool = { _ in false }
    ) -> StoredShortcut? {
        effectivePersistedShortcutResolvingLegacyConflicts(
            candidate,
            defaultShortcut: hostDefault,
            normalizing: { shortcut in
                shortcutBindingPolicyResult(for: shortcut) == .accepted
                    ? shortcut.canonicalized()
                    : nil
            },
            conflictsWithReservedShortcut: conflictsWithReservedShortcut,
            explicitlyConfiguredShortcut: explicitlyConfiguredShortcut,
            bindingsConflict: bindingsConflict
        )
    }

    /// Consumer-normalized variant used by the app runtime and Settings UI.
    ///
    /// - Parameters:
    ///   - candidate: The configured shortcut, or `nil` when no override exists.
    ///   - hostDefault: An optional host-owned default. Pass
    ///     ``StoredShortcut/unbound`` to explicitly disable the built-in value.
    public func effectivePersistedShortcutResolvingLegacyConflicts(
        _ candidate: StoredShortcut?,
        defaultShortcut hostDefault: StoredShortcut? = nil,
        normalizing: (StoredShortcut) -> StoredShortcut?,
        conflictsWithReservedShortcut: (StoredShortcut) -> Bool,
        explicitlyConfiguredShortcut: (ShortcutAction) -> StoredShortcut?,
        bindingsConflict: (
            _ proposed: StoredShortcut,
            _ configuredAction: ShortcutAction,
            _ configured: StoredShortcut
        ) -> Bool
    ) -> StoredShortcut? {
        guard let resolved = effectivePersistedShortcut(
            candidate,
            defaultShortcut: hostDefault,
            normalizing: normalizing,
            conflictsWithReservedShortcut: conflictsWithReservedShortcut
        ) else {
            return nil
        }
        guard candidate != resolved,
              let normalizedDefault = (hostDefault ?? defaultShortcut).flatMap(normalizing),
              resolved == normalizedDefault,
              let legacyAction = legacyActionDisplacingBuiltInDefault,
              let legacyShortcut = explicitlyConfiguredShortcut(legacyAction),
              legacyShortcut.isUnbound
                || bindingsConflict(resolved, legacyAction, legacyShortcut) else {
            return resolved
        }
        return nil
    }

    private var legacyActionDisplacingBuiltInDefault: ShortcutAction? {
        switch self {
        case .reopenClosedBrowserPanel:
            return .reopenClosedWorkspace
        default:
            return nil
        }
    }
}
