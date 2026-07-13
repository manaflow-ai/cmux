internal import Foundation

struct GitDiffOperationDeadline: Sendable {
    @TaskLocal static var current: GitDiffOperationDeadline?

    let uptime: TimeInterval

    init(timeoutSeconds: Double) {
        uptime = ProcessInfo.processInfo.systemUptime + max(0, timeoutSeconds)
    }

    var remainingSeconds: Double {
        uptime - ProcessInfo.processInfo.systemUptime
    }
}
