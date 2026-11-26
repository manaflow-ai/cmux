import Foundation

extension CloudMachineLink {
    /// Waits for the link client's stderr reader to reach EOF, so an exit error
    /// reads its last lines: they can still be in flight when the process
    /// exits. A child the client started can hold the pipe open, so the wait
    /// is bounded.
    nonisolated static func awaitStderrDrain(_ drain: Task<Void, Never>, upTo limit: Duration = .seconds(1)) async {
        let drained = CloudLinkFirstValue<Bool>()
        Task.detached {
            await drain.value
            drained.resolve(true)
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            drained.resolve(false)
        }
        _ = await drained.result
    }
}
