/// An optional action displayed inside a mobile toast.
public struct MobileToastAction: Sendable {
    let label: MobileToastText
    let handler: @MainActor @Sendable () -> Void

    /// Creates an action.
    ///
    /// - Parameters:
    ///   - label: The action's visible label.
    ///   - handler: Work performed before the toast dismisses.
    public init(
        label: MobileToastText,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.label = label
        self.handler = handler
    }
}
