import Foundation

/// Whether one of the user's devices lets this Mac connect, and the switch that turns it off or on: the
/// owned-machine consent (`RemoteControlConsent`: `state(for: machineID)`, `set(machineID:on:)`), which the App
/// wires to a hub device by its id and name. Every device on the user's own account allows this Mac by default
/// (the account-wide own-device grant); this narrows one device.
@MainActor
public struct MacScreenRemoteAccess {
    /// The switch for the hub device (`id`, `name`): true on, false off, nil when it is not known for that device.
    public var allows: (_ id: String, _ name: String) -> Bool?
    /// Turns the device's switch on or off (a person's choice).
    public var set: (_ id: String, _ name: String, _ on: Bool) -> Void

    public init(allows: @escaping (String, String) -> Bool?, set: @escaping (String, String, Bool) -> Void) {
        self.allows = allows
        self.set = set
    }
}
