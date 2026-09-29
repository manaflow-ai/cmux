/// What happened when an action ran through `ActionRegistry.run`.
public enum ActionRunResult: Sendable, Hashable {
    case ran
    /// The handler ran and reported why it did nothing (`fail(_:)`).
    case failed(reason: String)
    /// Bound as unavailable in this build (`bindUnavailable`).
    case unavailable(reason: String)
    /// Not bound, not available in the current context, or disabled.
    case notRun
}

extension ActionRegistry {
    /// Binds `id` to a handler that never runs, with a user-facing reason.
    /// The action counts as bound (it has an owner and a schedule) but
    /// `isEnabled` is false, so it never claims a shortcut and the palette
    /// shows it disabled. Returns false when `id` is not in the catalog.
    @discardableResult
    public func bindUnavailable(_ id: ActionID, reason: String) -> Bool {
        guard bind(id, isEnabled: { false }, handler: {}) else { return false }
        unavailableReasons[canonicalID(for: id)] = reason
        return true
    }

    public func unavailableReason(for id: ActionID) -> String? {
        unavailableReasons[canonicalID(for: id)]
    }

    /// IDs bound as unavailable, in catalog order.
    public func unavailableActionIDs() -> [ActionID] {
        descriptors.map(\.id).filter { unavailableReasons[$0] != nil }
    }

    /// Called by a handler, while it runs synchronously, to report why it did
    /// nothing (no browser focused, daemon offline). `run` returns it as
    /// `.failed`; `perform` ignores it.
    public func fail(_ reason: String) {
        pendingFailure = reason
    }

    /// Performs like `perform(_:invocation:)` and reports the typed result.
    public func run(_ id: ActionID, invocation: ActionInvocation = ActionInvocation()) -> ActionRunResult {
        if isBound(id), let reason = unavailableReason(for: id) { return .unavailable(reason: reason) }
        pendingFailure = nil
        defer { pendingFailure = nil }
        guard perform(id, invocation: invocation) else { return .notRun }
        if let reason = pendingFailure { return .failed(reason: reason) }
        return .ran
    }
}
