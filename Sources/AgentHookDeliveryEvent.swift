import Foundation

/// An immutable lifecycle event accepted by cmux before hook delivery begins.
struct AgentHookDeliveryEvent: Sendable {
    let agent: String
    let subcommand: String
    let payload: String
    let socketPath: String
    let environment: [String: String]

    init?(params: [String: Any]) {
        guard let agent = params["agent"] as? String,
              let subcommand = params["subcommand"] as? String,
              let socketPath = params["socket_path"] as? String,
              let environment = params["environment"] as? [String: String],
              !agent.isEmpty,
              !subcommand.isEmpty,
              !socketPath.isEmpty else {
            return nil
        }
        let payload: String
        if let encodedPayload = params["payload"] as? String {
            payload = encodedPayload
        } else if let payloadJSON = params["payload_json"],
                  JSONSerialization.isValidJSONObject(payloadJSON),
                  let data = try? JSONSerialization.data(withJSONObject: payloadJSON),
                  let encodedPayload = String(data: data, encoding: .utf8) {
            payload = encodedPayload
        } else {
            return nil
        }
        self.agent = agent
        self.subcommand = subcommand
        self.payload = payload
        self.socketPath = socketPath
        self.environment = environment
    }
}
