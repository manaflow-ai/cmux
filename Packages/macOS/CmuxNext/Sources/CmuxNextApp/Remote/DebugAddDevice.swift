#if DEBUG
import CmuxNextSettings
import CmuxNextServer

/// `debug.add_device {computers?, network?, way?}` (captures): Add Device opens on a fixture listing
/// instead of `cmux device list`, so a capture shows the network and ~/.ssh/config rows without the
/// capture machine's own tailnet. `computers`: `[{name, address?, os?, mine?, ssh?}]` (`ssh`: a
/// ~/.ssh/config host); `network`: `"none"` for no Tailscale; `way`: the way to open on, or
/// `"auto"` to open as the card does on its own (default `"network"`). The fixture stays for the
/// rest of the app's run, which a capture starts fresh.
@MainActor
enum DebugAddDevice {
    /// The listing Add Device shows while set (``AddDeviceServices/app(_:)``).
    static var listing: DeviceListing?

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
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
        let way = params["way"]?.stringValue.map { AddDeviceWay(rawValue: $0) } ?? AddDeviceWay.network
        services.addDevice.open(way: way, over: services.windows.active?.window)
        return .object(["computers": .number(Double(available.count))])
    }
}
#endif
