/// A lifecycle action on one Cloud machine.
public enum CloudMachineAction: Sendable, Equatable {
    case pause
    case resume
    case delete
}

/// A failed lifecycle action, kept with the machine and action it hit so the
/// UI can show it on the right row with the right wording.
public struct CloudMachineActionFailure: Sendable, Equatable {
    public var machineID: String
    public var action: CloudMachineAction
    public var failure: CloudSessionFailure

    public init(machineID: String, action: CloudMachineAction, failure: CloudSessionFailure) {
        self.machineID = machineID
        self.action = action
        self.failure = failure
    }
}
