import Foundation

/// `device-setup {device, verb}`: Set Up cmux (`setup`) or Start cmux (`start`) on one of the
/// person's own Macs, run by the daemon (cmux-tui `devices`, the same steps as `cmux device
/// setup|start`). Each step comes as a `device-setup-step` event first (``stepEvent``), with the
/// fields of the CLI's step line; the reply is the run's summary `{device, summary, changed}`.
/// A daemon without it answers unknown command: the app hides the buttons then.
public struct DeviceSetupRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "device-setup"
    /// The event each step arrives as, before the reply.
    public static let stepEvent = "device-setup-step"
    /// The hub device name, which the daemon resolves like `cmux device`.
    public var device: String
    /// `setup` or `start`.
    public var verb: String

    public init(device: String, verb: String) {
        self.device = device
        self.verb = verb
    }

    /// Whether `error` is a daemon's refusal of a command it does not know (an older cmux-tui).
    public static func isUnknownCommand(_ error: any Error) -> Bool {
        guard case let DaemonError.command(_, message, _, _, _) = error else { return false }
        let text = message.lowercased()
        return text.contains("unknown variant") || text.contains("unknown command") || text.contains("unknown cmd")
    }
}
