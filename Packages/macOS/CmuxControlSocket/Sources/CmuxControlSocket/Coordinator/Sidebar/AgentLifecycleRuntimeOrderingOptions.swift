import Foundation

/// Parsed optional ordering identity for `set_agent_lifecycle`.
struct AgentLifecycleRuntimeOrderingOptions: Equatable, Sendable {
    let runtimePIDKey: String?
    let runtimePID: Int32?
    let runtimeStartSeconds: Int64?
    let runtimeStartMicroseconds: Int64?
    let revision: UInt64?
    let isValid: Bool

    init(options: [String: String]) {
        runtimePIDKey = options["runtime-key"]
        runtimePID = options["runtime-pid"].flatMap(Int32.init)
        runtimeStartSeconds = options["runtime-start-seconds"].flatMap(Int64.init)
        runtimeStartMicroseconds = options["runtime-start-microseconds"].flatMap(Int64.init)
        revision = options["status-revision"].flatMap(UInt64.init)

        let hasAnyOrdering = [
            "runtime-key", "runtime-pid", "status-revision",
            "runtime-start-seconds", "runtime-start-microseconds",
        ].contains { options[$0] != nil }
        let hasAnyStart = options["runtime-start-seconds"] != nil ||
            options["runtime-start-microseconds"] != nil
        let hasCompleteOrdering = runtimePIDKey != nil && runtimePID != nil && revision != nil
        let hasValidStart = runtimeStartSeconds.map { $0 >= 0 } == true &&
            runtimeStartMicroseconds.map { (0..<1_000_000).contains($0) } == true
        isValid = (!hasAnyOrdering || hasCompleteOrdering) && (!hasAnyStart || hasValidStart)
    }
}
