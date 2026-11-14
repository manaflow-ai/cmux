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
    /// Replayed inventory establishes a baseline; it is not a newly opened app.
    public let known: Bool
    /// A browser can open it: a UDP listener never answers HTTP, so it gets no Open app card.
    public var isBrowserPreview: Bool { proto.lowercased() == "tcp" }

    public init(machineID: String, port: Int, proto: String, process: String?, state: State, known: Bool = false) {
        self.machineID = machineID
        self.port = port
        self.proto = proto
        self.process = process
        self.state = state
        self.known = known
    }

    private struct Event: Decodable {
        struct Payload: Decodable {
            var machine: String
            var port: Int
            var proto: String?
            var process: String?
            var state: String
            var snapshot: Bool?
            var replayed: Bool?
            var known: Bool?
        }

        var name: String
        var data: Payload?
        var snapshot: Bool?
        var replayed: Bool?
    }

    private struct MachineEvent: Decodable {
        struct Payload: Decodable {
            var machine: String
            var kind: String
            var data: Detail?
            var snapshot: Bool?
            var replayed: Bool?
        }
        struct Detail: Decodable {
            var snapshot: Bool?
            var replayed: Bool?
            var port: Int
            var proto: String?
            var process: String?
        }
        var name: String
        var data: Payload?
        var snapshot: Bool?
        var replayed: Bool?
    }

    /// Parses an app-server event, ignoring unrelated apps and malformed payloads.
    public static func parse(appServerEvent: Data) -> CloudPortChange? {
        if let event = try? JSONDecoder().decode(Event.self, from: appServerEvent),
           event.name == eventName, let data = event.data, data.port > 0,
           let state = State(rawValue: data.state) {
            return CloudPortChange(machineID: data.machine, port: data.port, proto: data.proto ?? "tcp",
                                   process: data.process, state: state,
                                   known: event.snapshot == true || event.replayed == true || data.known == true || data.snapshot == true || data.replayed == true)
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
                               process: detail.process, state: state,
                               known: event.snapshot == true || event.replayed == true || data.snapshot == true || data.replayed == true || detail.snapshot == true || detail.replayed == true)
    }

    /// Parses the ephemeral `cloud.machine.event` frame sent on `/v1/wire/cloud`.
    public static func parseWireFrame(_ frame: Data) -> CloudPortChange? {
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              object["t"] as? String == "ephemeral",
              object["event"] as? String == "cloud.machine.event",
              var data = object["data"] as? [String: Any] else { return nil }
        if object["snapshot"] as? Bool == true { data["snapshot"] = true }
        if object["replayed"] as? Bool == true { data["replayed"] = true }
        let envelope: [String: Any] = ["name": "cmux.cloud.machine.event", "data": data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return parse(appServerEvent: encoded)
    }
}
