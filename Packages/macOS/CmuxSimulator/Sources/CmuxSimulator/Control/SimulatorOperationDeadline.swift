import Foundation

/// Receipt deadlines sized to cover the complete sequence of bounded worker
/// and `simctl` operations performed by one public Simulator command.
public enum SimulatorOperationDeadline {
    public static let selectDevice: TimeInterval = 430
    public static let recover: TimeInterval = 370
    public static let interfaceRead: TimeInterval = 130
    public static let interfaceMutation: TimeInterval = 250
    public static let permissionRead: TimeInterval = 35
    public static let permissionMutation: TimeInterval = 70
    public static let permissionResetAll: TimeInterval = 190

    /// Keeps the CLI connection alive until the app has completed its receipt.
    public static func clientTimeout(for receiptTimeout: TimeInterval) -> TimeInterval {
        receiptTimeout + 5
    }
}
