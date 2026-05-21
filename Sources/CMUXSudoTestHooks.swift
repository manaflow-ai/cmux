import Darwin
import Foundation

#if DEBUG
enum CMUXSudoTestHooks {
    nonisolated(unsafe) static var approvalOverride: ((CMUXSudoCommandRequest) -> CMUXSudoApprovalResult)?
    nonisolated(unsafe) static var helperOverride: ((CMUXSudoSignedHelperEnvelope) -> CMUXSudoHelperExecutionResult)?
    nonisolated(unsafe) static var isDescendantOverride: ((pid_t) -> Bool)?
    nonisolated(unsafe) static var processArgumentsOverride: ((pid_t) -> CmuxTopProcessArguments?)?
    nonisolated(unsafe) static var surfaceExistsOverride: ((UUID, UUID) -> Bool)?
    nonisolated(unsafe) static var auditLogURLOverride: URL?

    static func reset() {
        approvalOverride = nil
        helperOverride = nil
        isDescendantOverride = nil
        processArgumentsOverride = nil
        surfaceExistsOverride = nil
        auditLogURLOverride = nil
        CMUXSudoPendingRequestStore.shared.reset()
    }
}
#endif
