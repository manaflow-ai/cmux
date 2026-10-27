#if DEBUG
import CmuxNextDaemon
import CmuxNextServer

/// `debug.add_device {computers?, network?, off?}` (captures): Add Device opens on a fixture listing
/// instead of `cmux device list`, so a capture shows the network and ~/.ssh/config rows without the
/// capture machine's own tailnet. `computers`: `[{name, address?, os?, mine?, ssh?}]` (`ssh`: a
/// ~/.ssh/config host); `network`: `"none"` for no Tailscale. `off: true` reads the real list again.
@MainActor
enum DebugAddDevice {
    /// The listing Add Device shows while set (``AddDeviceServices/app(_:)``).
    static var listing: DeviceListing?

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["off"]?.boolValue == true {
            listing = nil
            return .object(["off": .bool(true)])
        }
        let rows = params["computers"]?.arrayValue ?? [
            .object(["name": .string("studio"), "os": .string("macOS"), "mine": .bool(true)]),
            .object(["name": .string("build-box"), "os": .string("linux")]),
            .object(["name": .string("devbox"), "ssh": .bool(true)]),
            .object(["name": .string("gpu-west"), "ssh": .bool(true)]),
        ]
        let up = params["network"]?.stringValue != "none"
        let available = rows.compactMap { row -> DeviceListing.Available? in
            guard let name = row["name"]?.stringValue else { return nil }
            let ssh = row["ssh"]?.boolValue ?? false
            return DeviceListing.Available(name: name, address: row["address"]?.stringValue ?? (ssh ? name : "\(name).example.ts.net"),
                                           os: row["os"]?.stringValue ?? "", mine: row["mine"]?.boolValue ?? ssh, fromSSHConfig: ssh)
        }
        listing = DeviceListing(network: .init(kind: up ? "tailscale" : "none", up: up, this: up ? "this-mac" : nil,
                                               detail: up ? nil : "Tailscale is not installed on this computer."),
                                available: available)
        services.addDevice.open(way: .network, over: services.windows.active?.window)
        return .object(["computers": .number(Double(available.count))])
    }
}
#endif
