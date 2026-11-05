import Foundation

extension CEFRuntime {
    /// Runs `body`, work that runs after this pass's frame committed (a stand-in tab's page, made after its key's
    /// frame). Inert until the fix wires it.
    func afterFrameCommitted(_ body: () -> Void) {
        body()
    }
}
