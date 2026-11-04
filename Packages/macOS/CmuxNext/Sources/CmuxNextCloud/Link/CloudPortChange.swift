public import Foundation

/// A listening port change from the Cloud app server's machine event stream.
public struct CloudPortChange: Equatable, Sendable {
    public enum State: String, Sendable {
        case opened = "up"
        case closed = "down"
    }

    public static let eventName = "cmux.cloud.port.changed"

    public let machineID: String
    public let port: Int
    public let proto: String
    public let process: String?
    public let state: State

    public init(machineID: String, port: Int, proto: String, process: String?, state: State) {
        self.machineID = machineID
        self.port = port
        self.proto = proto
        self.process = process
        self.state = state
    }

    private struct Event: Decodable {
        struct Payload: Decodable {
            var machine: String
            var port: Int
            var proto: String?
            var process: String?
            var state: String
        }

        var name: String
        var data: Payload?
    }

    private struct MachineEvent: Decodable {
        struct Payload: Decodable {
            var machine: String
            var kind: String
            var data: Detail?
        }
        struct Detail: Decodable {
            var port: Int
            var proto: String?
            var process: String?
        }
        var name: String
        var data: Payload?
    }

    /// Parses an app-server event, ignoring unrelated apps and malformed payloads.
    public static func parse(appServerEvent: Data) -> CloudPortChange? {
        if let event = try? JSONDecoder().decode(Event.self, from: appServerEvent),
           event.name == eventName, let data = event.data, data.port > 0,
           let state = State(rawValue: data.state) {
            return CloudPortChange(machineID: data.machine, port: data.port, proto: data.proto ?? "tcp",
                                   process: data.process, state: state)
        }
        guard let event = try? JSONDecoder().decode(MachineEvent.self, from: appServerEvent),
              event.name == "cmux.cloud.machine.event", let data = event.data,
              let detail = data.data, detail.port > 0 else { return nil }
        let state: State
        switch data.kind {
        case "service.port.opened": state = .opened
        case "service.port.closed": state = .closed
        default: return nil
        }
        return CloudPortChange(machineID: data.machine, port: detail.port, proto: detail.proto ?? "tcp",
                               process: detail.process, state: state)
    }

    /// Parses the ephemeral `cloud.machine.event` frame sent on `/v1/wire/cloud`.
    public static func parseWireFrame(_ frame: Data) -> CloudPortChange? {
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["t"] as? String == "ephemeral",
              object["event"] as? String == "cloud.machine.event",
              let data = object["data"] else { return nil }
        let envelope: [String: Any] = ["name": "cmux.cloud.machine.event", "data": data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return parse(appServerEvent: encoded)
    }
}
