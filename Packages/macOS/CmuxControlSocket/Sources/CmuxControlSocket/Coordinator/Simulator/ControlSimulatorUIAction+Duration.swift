extension ControlSimulatorUIAction {
    /// A conservative bound for declared delays and known internal pacing.
    public var estimatedDurationMilliseconds: Int64 {
        controlSimulatorUIEstimatedDuration(self)
    }

    /// Whether the action can finish before the server's receipt deadline.
    public var fitsReceiptDeadline: Bool {
        estimatedDurationMilliseconds <= Self.maximumEstimatedDurationMilliseconds
    }
}
