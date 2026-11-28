internal import CmuxMobileShellModel
import Foundation

/// Shares one catalog request between prefetch and any open composer.
@MainActor
final class MobileTaskModelRefreshRequest {
    let connectionIdentity: String?
    var task: Task<Void, Never>?
    var isFinished: Bool { outcome != nil }
    private var outcome: MobileTaskModelRefreshOutcome?
    private var waiters: [UUID: CheckedContinuation<MobileTaskModelRefreshOutcome, Never>] = [:]
    private var observers: [UUID: @MainActor (MobileTaskModelListResult) -> Void] = [:]

    init(connectionIdentity: String?) {
        self.connectionIdentity = connectionIdentity
    }

    func value(
        didUpdate: (@MainActor (MobileTaskModelListResult) -> Void)?
    ) async -> MobileTaskModelRefreshOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .stopped(.cancelled))
                    return
                }
                if let outcome {
                    continuation.resume(returning: outcome)
                    return
                }
                waiters[id] = continuation
                observers[id] = didUpdate
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(returning: .stopped(.cancelled))
                self.observers[id] = nil
                if self.waiters.isEmpty { self.cancel() }
            }
        }
    }

    func publish(_ result: MobileTaskModelListResult) {
        for observer in Array(observers.values) { observer(result) }
    }

    func finish(_ result: MobileTaskModelRefreshOutcome) {
        guard outcome == nil else { return }
        outcome = result
        let continuations = Array(waiters.values)
        waiters.removeAll()
        observers.removeAll()
        task = nil
        for continuation in continuations { continuation.resume(returning: result) }
    }

    func cancel() {
        task?.cancel()
        finish(.stopped(.cancelled))
    }
}
