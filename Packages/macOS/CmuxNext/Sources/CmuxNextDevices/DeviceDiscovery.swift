public import Foundation

/// What Your Devices can truly say while it lists nothing, as Rust decides (`cloud_identity_device_discovery`,
/// cmux-cloud-config `device_list::discovery`). The hub is `ready` once this device registers, before the
/// list is read, so "none of your devices" is said only after a read succeeded; a failure says why
/// (Leo, 2026-11-19, ask-6a79af928f: "i simply dont see ANYTHING on the scren sharing screen").
public enum DeviceDiscovery: Sendable, Equatable {
    /// Rows to list.
    case list
    /// Registering, connecting, or waiting for the first read.
    case finding
    /// The list cannot be read.
    case failed(Reason, detail: String?)
    /// A read succeeded and holds no device to show.
    case noDevices

    public enum Reason: String, Sendable, Decodable {
        case hub, list, connection, replaced, removed, signedOut
    }

    /// The state of `hub` with `shown` rows to list.
    @MainActor
    public static func of(_ hub: DeviceHub, shown: Int) -> DeviceDiscovery {
        let status: (String, String?) = switch hub.status {
        case .idle: ("idle", nil)
        case .starting: ("starting", nil)
        case .ready: ("ready", nil)
        case let .failed(detail): ("failed", detail)
        }
        let connection: (String, String?) = switch hub.connection {
        case .disconnected: ("disconnected", nil)
        case .connecting: ("connecting", nil)
        case .connected: ("connected", nil)
        case let .reconnecting(detail): ("reconnecting", detail)
        case .replaced: ("replaced", nil)
        case .removed: ("removed", nil)
        case .signedOut: ("signedOut", nil)
        }
        return make(status: status.0, statusDetail: status.1, listed: hub.devicesListed,
                    listError: hub.devicesListError?.description, connection: connection.0,
                    connectionDetail: connection.1, shown: shown)
    }

    /// Rust's answer for these facts. Without one: the list with rows, else finding (never "none").
    public static func make(status: String, statusDetail: String? = nil, listed: Bool, listError: String? = nil,
                            connection: String, connectionDetail: String? = nil, shown: Int) -> DeviceDiscovery {
        struct Request: Encodable {
            var status: String, statusDetail: String?, listed: Bool, listError: String?
            var connection: String, connectionDetail: String?, shown: Int
        }
        struct Reply: Decodable { var state: String, reason: Reason?, detail: String? }
        let request = Request(status: status, statusDetail: statusDetail, listed: listed, listError: listError,
                              connection: connection, connectionDetail: connectionDetail, shown: shown)
        guard let data = try? JSONEncoder().encode(request), let answer = AppRules.call("cloud_identity_device_discovery", data),
              let reply = try? JSONDecoder().decode(Reply.self, from: answer) else {
            return shown > 0 ? .list : .finding
        }
        switch reply.state {
        case "list": return .list
        case "none": return .noDevices
        case "failed": return .failed(reply.reason ?? .list, detail: reply.detail)
        default: return .finding
        }
    }
}
