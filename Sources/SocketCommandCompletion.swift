import Foundation

struct SocketCommandCompletion: Equatable, Sendable {
    let command: SocketCommandObservabilityCommand
    let status: SocketCommandResponseStatus
    let durationNanoseconds: UInt64
    let responseByteCount: Int
    let completionThread: SocketCommandCompletionThread

    var durationMilliseconds: Double {
        Double(durationNanoseconds) / 1_000_000
    }

    var formattedMilliseconds: String {
        String(format: "%.2f", durationMilliseconds)
    }
}
