import CmuxNextSettings
public import Foundation

/// The app's two fixed owner operations. The CLI owns selection and generation fencing;
/// this bridge resolves native workspace ownership and forwards only that scope.
public struct CloudTurnCommands: Sendable {
    /// A workspace's native logical machine, and how the app reconnects it after replacement.
    public struct Scope: Sendable {
        public let machine: String
        public let confirmed: (@Sendable () async throws -> Void)?
        public let reconnect: @Sendable (String, Int) async throws -> Void
        public init(machine: String, confirmed: (@Sendable () async throws -> Void)? = nil,
                    reconnect: @escaping @Sendable (String, Int) async throws -> Void) {
            self.machine = machine
            self.confirmed = confirmed
            self.reconnect = reconnect
        }
    }

    /// The validated owner request, forwarded by the app with its own authentication.
    public struct Rewind: Sendable {
        public let workspace: String
        public let session: String
        public let turn: String
        public let machine: String
        public let generation: Int
        public let key: String
    }

    private let state: @Sendable (String) async throws -> Data
    private let connection: @Sendable (String) async throws -> Data
    private let rewind: @Sendable (Rewind) async throws -> Data
    private let scope: @Sendable (String) async throws -> Scope

    public init(state: @escaping @Sendable (String) async throws -> Data,
                connection: @escaping @Sendable (String) async throws -> Data,
                rewind: @escaping @Sendable (Rewind) async throws -> Data,
                scope: @escaping @Sendable (String) async throws -> Scope) {
        self.state = state
        self.connection = connection
        self.rewind = rewind
        self.scope = scope
    }

    /// Typed control methods, with a bounded restore deadline and no raw URL forwarding.
    public var methods: [ControlMethod] {
        [method("cloud.turn.state", rewind: false), method("cloud.turn.rewind", rewind: true)]
    }

    private func method(_ name: String, rewind: Bool) -> ControlMethod {
        .async(name) { call in
            let workspace = try Self.text(call.params, "workspace")
            let context = try await scope(workspace)
            let data: Data
            if rewind {
                let machine = try Self.text(call.params, "expectedMachine")
                guard machine == context.machine,
                      let raw = call.params["expectedGeneration"]?.doubleValue, let generation = Int(exactly: raw), generation >= 0
                else { throw ControlError(code: "cloud.turn.scope", message: "The workspace machine changed. Read its turn state again.") }
                data = try await self.rewind(Rewind(workspace: workspace, session: Self.text(call.params, "session"),
                                               turn: Self.text(call.params, "turn"), machine: machine, generation: generation,
                                               key: Self.text(call.params, "clientKey")))
            } else {
                data = try await state(workspace)
            }
            guard let value = CmuxNextSettings.JSONValue(foundation: try JSONSerialization.jsonObject(with: data)),
                  (rewind ? value["machine"]?["id"]?.stringValue : value["machineId"]?.stringValue) == context.machine
            else { throw ControlError(code: "cloud.turn.scope", message: "The platform returned a different workspace machine.") }
            try await context.confirmed?()
            if rewind {
                let data = try await connection(workspace)
                guard let target = CmuxNextSettings.JSONValue(foundation: try JSONSerialization.jsonObject(with: data)),
                      target["machineId"]?.stringValue == context.machine,
                      let raw = target["generation"]?.doubleValue, let generation = Int(exactly: raw), generation >= 0,
                      raw == value["generation"]?.doubleValue,
                      let provider = target["provider"]?.stringValue, provider == "freestyle" || provider == "freestyle-vm-api",
                      let machine = target["connectionMachine"]?.stringValue, machine.range(of: #"^vm_[a-z0-9]{20}$"#, options: .regularExpression) != nil
                else { throw ControlError(code: "cloud.turn.connection", message: "The machine rewound, but its current connection target could not be verified. Retry with the same key.") }
                try await context.reconnect(machine, generation)
            }
            return value
        }.withDeadline(.fixed(.seconds(300)))
    }

    private static func text(_ params: [String: CmuxNextSettings.JSONValue], _ name: String) throws -> String {
        guard let value = params[name]?.stringValue, !value.isEmpty, value.utf8.count <= 256 else {
            throw ControlError(code: "invalid_params", message: "Missing or invalid \(name).")
        }
        return value
    }
}
