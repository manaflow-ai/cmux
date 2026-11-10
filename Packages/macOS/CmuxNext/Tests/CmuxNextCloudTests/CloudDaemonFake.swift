@testable import CmuxNextCloud
import Foundation

/// A daemon that records each `cloud.*` call and answers it with `answer` (an SDK envelope).
final class CloudDaemonFake: @unchecked Sendable {
    // Unchecked: every field is read and written under `lock`.
    struct Sent {
        var operation: String
        var mutation: Bool
        var params: [String: Any]
        var args: [String: Any] { params["args"] as? [String: Any] ?? [:] }
    }

    private let lock = NSLock()
    private var calls: [Sent] = []
    private let answer: @Sendable (_ operation: String, _ args: [String: Any]) -> String

    init(answer: @escaping @Sendable (_ operation: String, _ args: [String: Any]) -> String = { _, _ in CloudDaemonFake.value("{}") }) {
        self.answer = answer
    }

    var daemon: CloudDaemon {
        CloudDaemon(send: { [self] operation, mutation, params, _ in
            let object = (try? JSONSerialization.jsonObject(with: Data(params.text.utf8))) as? [String: Any] ?? [:]
            let sent = Sent(operation: operation, mutation: mutation, params: object)
            lock.withLock { calls.append(sent) }
            return Data(answer(operation, sent.args).utf8)
        })
    }

    var sent: [Sent] { lock.withLock { calls } }

    /// A mutation's answer of `json`.
    static func value(_ json: String) -> String { #"{"ok":true,"result":{"value":"# + json + #","generation":"g","revision":"0","replayed":false}}"# }
    /// A read's answer of `json`.
    static func read(_ json: String) -> String { #"{"ok":true,"result":"# + json + "}" }
    /// The daemon ran the call and it failed with `failure` (cmux-cloud-api `Failure::json`).
    static func failed(_ failure: String) -> String {
        #"{"ok":false,"error":{"code":"operation.failed","message":"refused","details":{"operation":"cloud.x","reason":"http","extra":{"failure":"# + failure + "}}}}"
    }
}
