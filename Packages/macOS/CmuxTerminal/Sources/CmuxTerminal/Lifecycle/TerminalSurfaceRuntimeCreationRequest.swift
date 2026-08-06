internal import Foundation

// Safety: the only non-Sendable member is a MainActor-isolated closure. The
// coordinator invokes it on MainActor and transfers no captured value elsewhere.
struct TerminalSurfaceRuntimeCreationRequest: @unchecked Sendable {
    let id: UUID
    let reason: String
    let operation: @MainActor @Sendable () async -> Void
    let completion: TerminalSurfaceRuntimeTeardownCompletion
}
