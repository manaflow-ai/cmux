import CMUXAgentLaunch
import CryptoKit
import Foundation

/// An immutable wrapper hook accepted by cmux before delivery begins.
nonisolated struct AgentHookDeliveryEvent: Sendable {
    static let maximumPayloadBytes = 8 * 1024 * 1024
    static let maximumEnvironmentBytes = 256 * 1024

    let deliveryID: String
    let agent: String
    let subcommand: String
    let payload: Data
    let socketPath: String
    let environment: [String: String]

    /// Events for one terminal surface must retain lifecycle order. Independent
    /// surfaces may drain concurrently without changing observable semantics.
    var orderingKey: String {
        Self.orderingKey(
            deliveryID: deliveryID,
            socketPath: socketPath,
            environment: environment
        )
    }

    static func orderingKey(
        deliveryID: String,
        socketPath: String,
        environment: [String: String]
    ) -> String {
        let identity: [String]
        if let surfaceID = environment["CMUX_SURFACE_ID"], !surfaceID.isEmpty {
            identity = ["surface", socketPath, surfaceID]
        } else if let processID = environment["CMUX_CODEX_PID"], !processID.isEmpty {
            identity = ["process", socketPath, processID]
        } else {
            identity = ["delivery", deliveryID]
        }
        var hasher = SHA256()
        for component in identity {
            Self.hash(Data(component.utf8), into: &hasher)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    /// A stable digest used to reject accidental reuse of one delivery ID for
    /// different contents while treating retry submissions as duplicates.
    var contentDigest: Data {
        var hasher = SHA256()
        Self.hash(Data(agent.utf8), into: &hasher)
        Self.hash(Data(subcommand.utf8), into: &hasher)
        Self.hash(payload, into: &hasher)
        for key in environment.keys.sorted() {
            Self.hash(Data(key.utf8), into: &hasher)
            Self.hash(Data((environment[key] ?? "").utf8), into: &hasher)
        }
        return Data(hasher.finalize())
    }

    init?(params: [String: Any]) {
        guard let deliveryID = params["delivery_id"] as? String,
              !deliveryID.isEmpty,
              deliveryID.utf8.count <= 256,
              deliveryID.utf8.allSatisfy(Self.isDeliveryIDByte),
              let agent = params["agent"] as? String,
              agent == "codex",
              let subcommand = params["subcommand"] as? String,
              [
                  "session-start", "prompt-submit", "stop",
                  "pre-tool-use", "post-tool-use", "notification",
              ].contains(subcommand),
              let payload = Self.decodePayload(params),
              payload.count <= Self.maximumPayloadBytes,
              let environment = Self.decodeEnvironment(params),
              let socketPath = environment["CMUX_SOCKET_PATH"],
              !socketPath.isEmpty,
              socketPath.utf8.count <= 4_096 else {
            return nil
        }

        self.deliveryID = deliveryID
        self.agent = agent
        self.subcommand = subcommand
        self.payload = payload
        self.socketPath = socketPath
        self.environment = environment
    }

    private static func decodePayload(_ params: [String: Any]) -> Data? {
        if let encoded = params["payload_b64"] as? String {
            guard encoded.utf8.count <= ((maximumPayloadBytes + 2) / 3) * 4 + 4 else {
                return nil
            }
            return Data(base64Encoded: encoded)
        }

        // Keep the legacy form for one rolling-upgrade window. New producers
        // use payload_b64 so every stdin byte survives unchanged.
        if let payload = params["payload"] as? String {
            return Data(payload.utf8)
        }
        if let payloadJSON = params["payload_json"],
           JSONSerialization.isValidJSONObject(payloadJSON) {
            return try? JSONSerialization.data(withJSONObject: payloadJSON, options: [.sortedKeys])
        }
        return nil
    }

    private static func decodeEnvironment(_ params: [String: Any]) -> [String: String]? {
        let environment: [String: String]
        if let encoded = params["environment_b64"] as? String {
            guard encoded.utf8.count <= ((maximumEnvironmentBytes + 2) / 3) * 4 + 4,
                  let data = Data(base64Encoded: encoded),
                  data.count <= maximumEnvironmentBytes,
                  let decoded = decodeNULTuples(data) else {
                return nil
            }
            environment = decoded
        } else if let legacy = params["environment"] as? [String: String] {
            environment = legacy
        } else {
            return nil
        }

        var totalBytes = 0
        for (key, value) in environment {
            guard key.utf8.count <= 128,
                  value.utf8.count <= 128 * 1024 else {
                return nil
            }
            totalBytes += key.utf8.count + value.utf8.count + 2
            guard totalBytes <= maximumEnvironmentBytes else { return nil }
        }
        // Unknown variables are ignored rather than rejecting the whole hook:
        // the native sender deliberately forwards its ambient environment so
        // this shared policy remains the sole admission source of truth.
        return AgentHookTransportEnvironmentPolicy().selectedEnvironment(from: environment)
            .filter { !$0.value.isEmpty }
    }

    private static func decodeNULTuples(_ data: Data) -> [String: String]? {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.count.isMultiple(of: 2) == false, fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count.isMultiple(of: 2) else { return nil }

        var environment: [String: String] = [:]
        environment.reserveCapacity(fields.count / 2)
        var index = 0
        while index < fields.count {
            guard let key = String(data: fields[index], encoding: .utf8),
                  let value = String(data: fields[index + 1], encoding: .utf8),
                  !key.isEmpty,
                  environment.updateValue(value, forKey: key) == nil else {
                return nil
            }
            index += 2
        }
        return environment
    }

    private static func hash(_ data: Data, into hasher: inout SHA256) {
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private static func isDeliveryIDByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "-")].contains(byte)
    }
}
