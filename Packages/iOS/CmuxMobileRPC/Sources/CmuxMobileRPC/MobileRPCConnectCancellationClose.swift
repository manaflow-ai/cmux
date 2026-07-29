internal import CMUXMobileCore
internal import os

/// Synchronously captures the physical close started by a connect task's
/// cancellation handler. The abandoned-connect cleaner combines this task
/// with any late candidate close under one route lease.
///
/// Safety: every mutable access is serialized by `closeTask`; the stored task
/// is `Sendable`, and this reference exposes no state outside that lock.
final class MobileRPCConnectCancellationClose: @unchecked Sendable {
    private let closeTask = OSAllocatedUnfairLock<
        Task<Void, Never>?
    >(initialState: nil)

    func start(_ candidate: any CmxByteTransport) {
        closeTask.withLock { closeTask in
            guard closeTask == nil else { return }
            closeTask = Task.detached {
                await candidate.close()
            }
        }
    }

    var task: Task<Void, Never>? {
        closeTask.withLock { $0 }
    }
}
