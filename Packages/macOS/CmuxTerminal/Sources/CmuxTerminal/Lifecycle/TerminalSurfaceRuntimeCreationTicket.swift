internal import Foundation

/// An awaitable ticket for one queued native surface creation.
struct TerminalSurfaceRuntimeCreationTicket: Sendable {
    private let completion: TerminalSurfaceRuntimeTeardownCompletion

    init(completion: TerminalSurfaceRuntimeTeardownCompletion) {
        self.completion = completion
    }

    func wait() async -> Bool {
        await completion.wait()
    }
}
