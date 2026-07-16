import Foundation

/// Receipt deadlines sized to cover the complete sequence of bounded worker
/// and `simctl` operations performed by one public Simulator command.
public struct SimulatorOperationDeadlines: Sendable {
    /// Maximum duration for selecting and attaching a Simulator device.
    public let selectDevice: TimeInterval
    /// Maximum duration for recovering an interrupted Simulator connection.
    public let recover: TimeInterval
    /// Maximum duration for reading Simulator interface state.
    public let interfaceRead: TimeInterval
    /// Maximum duration for mutating Simulator interface state.
    public let interfaceMutation: TimeInterval
    /// Maximum duration for reading Simulator permission state.
    public let permissionRead: TimeInterval
    /// Maximum duration for reading worker-backed inspection state.
    public let inspectionRead: TimeInterval
    /// Maximum duration for mutating one Simulator permission.
    public let permissionMutation: TimeInterval
    /// Maximum duration for resetting all Simulator permissions.
    public let permissionResetAll: TimeInterval
    /// Additional time for a text command to start and attach its pane worker.
    public let textInputReadiness: TimeInterval
    /// Additional time allowed for the CLI transport to receive a completed receipt.
    public let clientReceiptMargin: TimeInterval

    /// Creates an operation deadline policy.
    public init(
        selectDevice: TimeInterval = 550,
        recover: TimeInterval = 490,
        interfaceRead: TimeInterval = 130,
        interfaceMutation: TimeInterval = 250,
        permissionRead: TimeInterval = 35,
        inspectionRead: TimeInterval = 35,
        permissionMutation: TimeInterval = 70,
        permissionResetAll: TimeInterval = 190,
        textInputReadiness: TimeInterval? = nil,
        clientReceiptMargin: TimeInterval = 10
    ) {
        self.selectDevice = selectDevice
        self.recover = recover
        self.interfaceRead = interfaceRead
        self.interfaceMutation = interfaceMutation
        self.permissionRead = permissionRead
        self.inspectionRead = inspectionRead
        self.permissionMutation = permissionMutation
        self.permissionResetAll = permissionResetAll
        self.textInputReadiness = textInputReadiness ?? selectDevice
        self.clientReceiptMargin = clientReceiptMargin
    }

    /// Keeps the CLI connection alive until the app has completed its receipt.
    public func clientTimeout(for receiptTimeout: TimeInterval) -> TimeInterval {
        receiptTimeout + clientReceiptMargin
    }
}

/// Default operation deadlines used by cmux Simulator commands.
public let simulatorOperationDeadlines = SimulatorOperationDeadlines()
