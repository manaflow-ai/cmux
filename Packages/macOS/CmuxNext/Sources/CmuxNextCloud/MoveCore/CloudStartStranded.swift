public import Foundation

/// A Cloud start that fails after a machine was made for it, so the start can't go on, deletes that machine: a start
/// never leaves one running for nothing (Leo, 2026-11-10, on a start from ~/Projects whose copy failed with its new
/// machine left running: "did you guys not test these"). A failure whose Retry reuses the machine keeps it, and so does
/// a cancel; a machine the start found (the person's own, the workspace's, a reserved one it bound) is never deleted.
extension CloudMoveCLI.StartChatPlan {
    /// Whether `error` ends a start for good: everything but a failure whose Retry reuses the machine, or a cancel.
    public nonisolated static func strands(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? CloudMoveFailure { return failure.retry == nil }
        return true
    }

    /// Whether this plan's machine was made for its start: the App made it (the plan named none) or the platform created it now.
    public nonisolated var madeForStart: Bool { machine == nil || madeForSend }

    /// `body`, the start's steps once its machine is up; when one strands the start (``strands(_:)``), the machine was made
    /// for it (``madeForStart``) and the account is still the one it began in (`sameAccount`), `delete` deletes it. The
    /// error goes on.
    @MainActor public func releasing<T>(sameAccount: @MainActor () -> Bool, delete: @MainActor () async throws -> Void,
                                        _ body: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if madeForStart, Self.strands(error), sameAccount() { try? await delete() }
            throw error
        }
    }
}
