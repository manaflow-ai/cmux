// Typed "cannot run" reasons. An action is either unavailable up front (a
// missing daemon capability or an unported feature: `bind(_:unavailable:)`)
// or refuses one invocation (no such target, pinned tab cannot be grouped:
// `refuse(_:)`). Both reach the control socket as `unavailable` with the
// reason, so no handler is a silent no-op.
extension ActionRegistry {
    /// Binds a handler whose availability depends on `reason`: while it
    /// returns a string the action is disabled in every surface and
    /// `action.run` reports that string.
    @discardableResult
    public func bind(
        _ id: ActionID,
        unavailable reason: @escaping @MainActor () -> String?,
        invoke: @escaping @MainActor (ActionInvocation) -> Void
    ) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        register(Action(
            id: descriptor.id,
            title: descriptor.title,
            keywords: descriptor.keywords,
            isEnabled: { reason() == nil },
            invoke: invoke,
            unavailableReason: reason,
            handler: {}
        ))
        return true
    }

    /// Binds an action that cannot run in this build, with the reason.
    @discardableResult
    public func bindUnavailable(_ id: ActionID, reason: String) -> Bool {
        bind(id, unavailable: { reason }, invoke: { _ in })
    }

    /// The bound action's current unavailable reason, if any.
    public func unavailableReason(for id: ActionID) -> String? {
        action(for: id)?.unavailableReason?()
    }

    /// Called by a handler that cannot act on this invocation. The reason
    /// is returned to a capturing caller (the control socket) and passed to
    /// `refusalObserver` (logging, a beep for keyboard and menu runs).
    public func refuse(_ reason: String) {
        if isCapturingRefusal { capturedRefusal = capturedRefusal ?? reason }
        refusalObserver?(reason)
    }

    /// Runs `body` (a synchronous `perform`) and returns the first refusal a
    /// handler reported during it.
    public func capturingRefusal(_ body: () -> Void) -> String? {
        let wasCapturing = isCapturingRefusal
        let previous = capturedRefusal
        isCapturingRefusal = true
        capturedRefusal = nil
        body()
        let reason = capturedRefusal
        isCapturingRefusal = wasCapturing
        capturedRefusal = previous
        return reason
    }

    /// Catalog IDs in `categories` without a handler.
    public func unboundActionIDs(in categories: Set<ActionCategory>) -> [ActionID] {
        descriptors.filter { categories.contains($0.category) && !isBound($0.id) }.map(\.id)
    }
}
