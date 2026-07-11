internal import Foundation

final class AnalyticsUploadTaskRegistry: Sendable {
    private enum Command: Sendable {
        case register(Task<AnalyticsUploadResult, Never>, UUID, CheckedContinuation<Bool, Never>)
        case remove(UUID)
        case setEnabled(Bool)
    }

    private let continuation: AsyncStream<Command>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task {
            var isEnabled = true
            var tasks: [UUID: Task<AnalyticsUploadResult, Never>] = [:]
            for await command in stream {
                switch command {
                case let .register(task, id, result):
                    guard isEnabled else {
                        result.resume(returning: false)
                        continue
                    }
                    tasks[id] = task
                    result.resume(returning: true)
                case let .remove(id):
                    tasks.removeValue(forKey: id)
                case let .setEnabled(enabled):
                    isEnabled = enabled
                    guard !enabled else { continue }
                    let tasksToCancel = tasks.values
                    tasks.removeAll()
                    for task in tasksToCancel { task.cancel() }
                }
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func register(_ task: Task<AnalyticsUploadResult, Never>, id: UUID) async -> Bool {
        await withCheckedContinuation { result in
            continuation.yield(.register(task, id, result))
        }
    }

    func remove(id: UUID) {
        continuation.yield(.remove(id))
    }

    func setEnabled(_ enabled: Bool) {
        continuation.yield(.setEnabled(enabled))
    }
}
