/// Presents and dismisses sudo review models for a coordinator.
@MainActor
public protocol SudoApprovalPresenting: AnyObject {
    /// Presents one review model, reusing an existing request window when possible.
    ///
    /// - Parameters:
    ///   - presentation: The model containing the exact script and request metadata.
    ///   - approve: The authoritative approval action.
    ///   - deny: The authoritative denial action.
    func present(
        _ presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void
    )

    /// Dismisses the review window for a terminal request.
    ///
    /// - Parameter id: The settled request identifier.
    func dismiss(id: String)

    /// Dismisses every review window without changing durable request state.
    func dismissAll()
}
