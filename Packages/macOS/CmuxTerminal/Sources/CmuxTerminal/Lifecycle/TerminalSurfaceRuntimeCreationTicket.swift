internal import Foundation

/// An awaitable ticket for one queued native surface creation.
struct TerminalSurfaceRuntimeCreationTicket: Sendable {
    private let completion: TerminalSurfaceRuntimeTeardownCompletion

    init(completion: TerminalSurfaceRuntimeTeardownCompletion) {
        self.completion = completion
    }

    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await completion.wait()
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }
}
