/// One tap step resolved from a shared UI snapshot before a batch mutates the screen.
public struct ControlSimulatorUITapStep: Sendable, Equatable {
    /// The target's process-scoped element reference.
    public let elementRef: String
    /// Delay before the tap in milliseconds.
    public let preDelayMilliseconds: Int
    /// Delay after the tap in milliseconds.
    public let postDelayMilliseconds: Int

    /// Creates one bounded batch tap step.
    ///
    /// - Parameters:
    ///   - elementRef: The target element reference.
    ///   - preDelayMilliseconds: Delay before the tap.
    ///   - postDelayMilliseconds: Delay after the tap.
    public init(
        elementRef: String,
        preDelayMilliseconds: Int = 0,
        postDelayMilliseconds: Int = 0
    ) {
        self.elementRef = elementRef
        self.preDelayMilliseconds = preDelayMilliseconds
        self.postDelayMilliseconds = postDelayMilliseconds
    }
}
