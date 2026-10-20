public import CmuxNextRemote
public import Foundation

/// A machine ``RemoteHostSource`` shows as a remote host (the App's `ServerMachineSession`).
@MainActor
public protocol RemoteHostSession: AnyObject {
    var machineID: String { get }
    var name: String { get }
    /// Why the host does not connect now (the list's reason); nil when it answered.
    var unavailableReason: String? { get set }
    /// Dialed on the home identity and on app activation.
    var autoConnect: Bool { get set }
    func connect()
    func disconnect()
    func close()
}

/// Where ``RemoteHostSource`` keeps remote hosts (the App's `MachineRegistry`).
@MainActor
public protocol RemoteHostRegistry: AnyObject {
    /// The remote hosts shown now.
    var remoteHosts: [any RemoteHostSession] { get }
    func remoteHost(_ machineID: String) -> (any RemoteHostSession)?
    /// Adds a host for `reach` whose daemon connection runs `cli host dial`; not connected yet.
    func addRemoteHost(_ reach: ServerReach, cli: URL?) -> any RemoteHostSession
    func removeRemoteHost(_ machineID: String)
    /// The machine ids of remote hosts the home session has a record for (connected before).
    func recordedRemoteHostIDs() -> Set<String>
}
