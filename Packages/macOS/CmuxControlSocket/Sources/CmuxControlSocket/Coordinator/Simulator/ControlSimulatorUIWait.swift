/// A bounded runtime UI wait.
public struct ControlSimulatorUIWait: Sendable, Equatable {
    /// The normalized predicate name.
    public let predicate: String
    /// An optional process-scoped element reference.
    public let elementRef: String?
    /// An optional exact accessibility identifier.
    public let identifier: String?
    /// An optional exact accessibility label.
    public let label: String?
    /// An optional exact normalized role.
    public let role: String?
    /// An optional exact accessibility value.
    public let value: String?
    /// An optional visible text fragment.
    public let text: String?
    /// The overall wait deadline in milliseconds.
    public let timeoutMilliseconds: Int
    /// The accessibility sampling interval in milliseconds.
    public let pollIntervalMilliseconds: Int
    /// The required stable-screen duration for the `settled` predicate.
    public let settledDurationMilliseconds: Int

    /// Creates one bounded wait request.
    ///
    /// - Parameters:
    ///   - predicate: The normalized predicate name.
    ///   - elementRef: An optional element reference.
    ///   - identifier: An optional exact accessibility identifier.
    ///   - label: An optional exact accessibility label.
    ///   - role: An optional exact normalized role.
    ///   - value: An optional exact accessibility value.
    ///   - text: An optional visible text fragment.
    ///   - timeoutMilliseconds: The overall deadline.
    ///   - pollIntervalMilliseconds: The accessibility sampling interval.
    ///   - settledDurationMilliseconds: The required stable-screen duration.
    public init(
        predicate: String,
        elementRef: String?,
        identifier: String?,
        label: String?,
        role: String?,
        value: String?,
        text: String?,
        timeoutMilliseconds: Int,
        pollIntervalMilliseconds: Int,
        settledDurationMilliseconds: Int
    ) {
        self.predicate = predicate
        self.elementRef = elementRef
        self.identifier = identifier
        self.label = label
        self.role = role
        self.value = value
        self.text = text
        self.timeoutMilliseconds = timeoutMilliseconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.settledDurationMilliseconds = settledDurationMilliseconds
    }
}
