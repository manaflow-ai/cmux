import CmuxNextActions

extension RegistryControlBridge {
    /// The catalog's actions as last built, with the action id each one's
    /// unavailable reason is read for. The bridge keeps one and patches its
    /// reasons in place; the context mask is added when it is published.
    @MainActor
    struct BuiltCatalog {
        private(set) var actions: [ControlActionInfo]
        /// The registry id of each action, in the same order.
        let ids: [ActionID]
        let aliases: [String: String]
        let debugActionsAvailable: Bool

        /// Everything but the reasons, which stay nil until ``apply(reasons:)``.
        init(registry: ActionRegistry) {
            // Localized once per build, not once per action.
            let categoryTitles = Dictionary(uniqueKeysWithValues: ActionCategory.allCases.map { ($0, $0.title) })
            let entries = registry.entries
            actions = entries.map { RegistryControlBridge.structureInfo(for: $0, in: registry, categoryTitles: categoryTitles) }
            ids = entries.map(\.descriptor.id)
            aliases = Dictionary(uniqueKeysWithValues: registry.aliases.map { ($0.key.rawValue, $0.value.rawValue) })
            debugActionsAvailable = DevTools.isEnabled
        }

        /// Each action's unavailable reason, in the order of ``ids``.
        var reasons: [String?] { actions.map(\.unavailableReason) }

        /// Stores `reasons` (one per id) and says whether any differed.
        @discardableResult
        mutating func apply(reasons: [String?]) -> Bool {
            guard zip(actions, reasons).contains(where: { $0.unavailableReason != $1 }) else { return false }
            actions = zip(actions, reasons).map { action, reason in
                var action = action
                action.unavailableReason = reason
                return action
            }
            return true
        }

        func catalog(contextMask: UInt32) -> ControlCatalog {
            ControlCatalog(
                actions: actions,
                contextMask: contextMask,
                aliases: aliases,
                targetKinds: ActionTargetKind.allCases.map(\.rawValue),
                debugActionsAvailable: debugActionsAvailable
            )
        }
    }
}
