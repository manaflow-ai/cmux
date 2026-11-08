import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// The local daemon's `cloud.*` operations, answered by the test: every call a Cloud API client
/// sends (its operation and fields), and the answer the test gives.
nonisolated final class FakeCloudAPI: Sendable {
    struct Call: Sendable {
        var operation: String
        var fields: [String: JSONValue]
        var args: [String: JSONValue] { fields["args"]?.objectValue ?? [:] }
        func field(_ name: String) -> String? { fields[name]?.stringValue }
    }

    private let state = Mutex<[Call]>([])
    private let answer: @Sendable (Call) throws -> JSONValue

    init(answer: @escaping @Sendable (Call) throws -> JSONValue = { _ in .object([:]) }) {
        self.answer = answer
    }

    var seen: [Call] { state.withLock { $0 } }
    var operations: [String] { seen.map(\.operation) }

    var caller: CloudAPICaller {
        CloudAPICaller { [self] operation, fields, mutation, _ in
            let call = Call(operation: operation, fields: fields)
            state.withLock { $0.append(call) }
            let value = try answer(call)
            return mutation ? .object(["value": value, "revision": .string("0"), "replayed": .bool(false)]) : value
        }
    }

    /// JSON text as the daemon would answer it.
    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    /// The daemon's refusal of a call, its `extra.failure` the crate's failure object.
    static func refusal(_ failure: String) -> DaemonError {
        .command(cmd: "cloud", message: "refused", code: "operation.failed",
                 details: .object(["reason": .string("http"), "extra": .object(["failure": json(failure)])]))
    }

    /// A classic client (`stack`) on this fake.
    func classic(team: String? = "team-1") -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        return CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { team }, caller: caller)
    }

    /// A Worker machines client (`worker`) on this fake.
    func worker(_ origin: String = "https://machines.standin.invalid", machineIO: CloudMachineIO? = nil) -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: URL(string: origin) ?? URL(fileURLWithPath: "/dev/null"), accessToken: { "session-access" },
                                      teamID: { "team_cmux" }, caller: caller, machineIO: machineIO)
    }
}

extension JSONValue {
    /// A whole number field, as the daemon reads it.
    var intValue: Int? { doubleValue.flatMap { Int(exactly: $0) } }
    var objectValue: [String: JSONValue]? {
        if case let .object(members) = self { return members }
        return nil
    }
}
