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
        noteBinding(descriptor.id, placeholder: false)
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
        guard let descriptor = descriptor(for: id) else { return false }
        noteBinding(descriptor.id, placeholder: true)
        register(Action(id: descriptor.id, title: descriptor.title, keywords: descriptor.keywords, isEnabled: { false },
                        invoke: { _ in }, unavailableReason: { reason }, handler: {})); return true
    }

    /// The bound action's current unavailable reason, if any.
    public func unavailableReason(for id: ActionID) -> String? {
        action(for: id)?.unavailableReason?()
    }

    /// Called by a handler that cannot act on this invocation. The reason
    /// is returned to a capturing caller (the control socket) and passed to
    /// `refusalObserver` (logging, a beep for keyboard and menu runs).
    ///
    /// `quiet` (R136): a navigation or focus move that has no target (no
    /// pane to the right, already at the edge, nothing was closed). Callers
    /// (CLI, MCP, socket, palette) still get the reason; the App shows no
    /// notice for a keyboard or menu run.
    public func refuse(_ reason: String, quiet: Bool = false) {
        if isCapturingRefusal { capturedRefusal = capturedRefusal ?? reason }
        if isReportingRefusal { reportedRefusal = reportedRefusal ?? reason }
        refusalObserver?(reason, quiet)
    }

    /// Like ``refuse(_:)`` for an explicit target that names nothing: the
    /// control socket answers `not_found` instead of `unavailable`.
    public func refuseNotFound(_ reason: String) {
        if isCapturingRefusal, capturedRefusal == nil { capturedRefusalIsNotFound = true }
        refuse(reason)
    }

    /// ``capturingRefusal(_:)`` that also says whether the refusal was
    /// ``refuseNotFound(_:)``.
    public func capturingTypedRefusal(_ body: () -> Void) -> (reason: String, isNotFound: Bool)? {
        let previous = capturedRefusalIsNotFound
        capturedRefusalIsNotFound = false
        let reason = capturingRefusal(body)
        let notFound = capturedRefusalIsNotFound
        capturedRefusalIsNotFound = previous
        return reason.map { ($0, notFound) }
    }

    /// A caller receives this refusal (capturing or reporting): the App
    /// neither beeps nor needs to, the caller shows or returns the reason.
    public var refusalHasCaller: Bool { isCapturingRefusal || isReportingRefusal }

    /// Runs `body` (a user-driven `perform`, such as a palette command) and
    /// returns the first refusal a handler reported during it, for the
    /// caller to show instead of a beep. Destructive actions still ask for
    /// confirmation (a capturing run refuses them instead).
    public func reportingRefusal(_ body: () -> Void) -> String? {
        let wasReporting = isReportingRefusal
        let previous = reportedRefusal
        isReportingRefusal = true
        reportedRefusal = nil
        body()
        let reason = reportedRefusal
        isReportingRefusal = wasReporting
        reportedRefusal = previous
        return reason
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
