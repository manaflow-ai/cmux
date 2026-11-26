public import Foundation

/// An awaitable handle for one native surface teardown.
public struct TerminalSurfaceRuntimeTeardownTicket: Sendable {
    /// Stable identity used by the surface to clear only its current teardown.
    public let id: UUID

    private let completion: TerminalSurfaceRuntimeTeardownCompletion

    init(
        id: UUID = UUID(),
        completion: TerminalSurfaceRuntimeTeardownCompletion
    ) {
        self.id = id
        self.completion = completion
    }

    /// Waits until the native free and callback-userdata releases finish.
    ///
    /// A `nil` deadline is the event-driven recovery wait used after a bounded
    /// foreground attempt has already reported failure.
    ///
    /// - Parameter timeout: Maximum wait, or `nil` to wait until completion.
    /// - Returns: `true` only when teardown completed.
    public func wait(timeout: Duration?) async -> Bool {
        guard let timeout else {
            return await completion.wait()
        }
        return await withTaskGroup(of: Bool.self) { group in
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
