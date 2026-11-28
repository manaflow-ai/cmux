public import Foundation

/// Parses `xcrun devicectl list devices --json-output -` into real iPhones
/// and iPads. Simulated entries are skipped (``SimctlDeviceList`` owns them),
/// as are other platforms.
public struct DevicectlDeviceList: Sendable {
    public init() {}

    private struct Output: Decodable {
        let result: Result
        struct Result: Decodable { let devices: [Entry] }
    }

    private struct Entry: Decodable {
        let identifier: String
        let connectionProperties: Connection?
        let deviceProperties: DeviceProps?
        let hardwareProperties: Hardware?

        struct Connection: Decodable {
            let pairingState: String?
            let transportType: String?
            let tunnelState: String?
        }
        struct DeviceProps: Decodable {
            let name: String?
            let osVersionNumber: String?
        }
        struct Hardware: Decodable {
            let marketingName: String?
            let platform: String?
            let reality: String?
            let udid: String?
            let deviceType: String?
        }
    }

    public func parse(_ json: Data) throws -> [PhoneDevice] {
        let output = try JSONDecoder().decode(Output.self, from: json)
        return output.result.devices.compactMap { entry -> PhoneDevice? in
            guard let hardware = entry.hardwareProperties, hardware.reality == "physical",
                  hardware.platform == "iOS" || hardware.platform == "iPadOS" else { return nil }
            let connection = entry.connectionProperties
            // devicectl opens the tunnel on demand, so a paired device counts as
            // ready; a far-away one fails at its first command with the tool's error.
            let connected = connection?.pairingState == "paired"
            let transport: String? = switch connection?.transportType {
            case "wired": "usb"
            case "localNetwork": "wifi"
            default: nil
            }
            let model = hardware.marketingName ?? hardware.deviceType ?? "iPhone"
            return PhoneDevice(
                id: PhoneDeviceID(mode: .device, raw: hardware.udid ?? entry.identifier),
                name: entry.deviceProperties?.name ?? model, model: model,
                osVersion: "iOS " + (entry.deviceProperties?.osVersionNumber ?? "?"),
                state: connected ? .ready : .disconnected, transport: transport)
        }
    }
}
