/// How one machine's part of an Update Everything run ended.
public nonisolated struct UpdateEverythingOutcome: Sendable, Equatable {
    /// The machine id.
    public var machineID: String
    /// The machine's name.
    public var name: String
    /// Why its update stopped, or nil when every step succeeded. Later steps on the machine do not
    /// run after a failure; other machines are not affected.
    public var failure: String?

    /// - Parameters:
    ///   - machineID: The machine id.
    ///   - name: The machine's name.
    ///   - failure: Why it stopped, or nil.
    public init(machineID: String, name: String, failure: String? = nil) {
        self.machineID = machineID
        self.name = name
        self.failure = failure
    }
}
