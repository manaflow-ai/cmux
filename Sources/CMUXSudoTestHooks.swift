import Darwin
import Foundation

#if DEBUG
enum CMUXSudoTestHooks {
    nonisolated(unsafe) static var approvalOverride: ((CMUXSudoCommandRequest) -> CMUXSudoApprovalResult)?
    nonisolated(unsafe) static var signedEnvelopeOverride: ((CMUXSudoCommandRequest) throws -> CMUXSudoSignedHelperEnvelope)?
    nonisolated(unsafe) static var helperAvailabilityOverride: (() -> CMUXSudoHelperServiceResult)?
    nonisolated(unsafe) static var helperOverride: ((CMUXSudoSignedHelperEnvelope) -> CMUXSudoHelperExecutionResult)?
    nonisolated(unsafe) static var isDescendantOverride: ((pid_t) -> Bool)?
    nonisolated(unsafe) static var trustedSurfaceScopeOverride: ((pid_t) -> CMUXSudoTrustedSurfaceScope?)?
    nonisolated(unsafe) static var workingDirectoryOverride: ((pid_t) -> String?)?
    nonisolated(unsafe) static var auditLogURLOverride: URL?

    static func reset() {
        approvalOverride = nil
        signedEnvelopeOverride = nil
        helperAvailabilityOverride = nil
        helperOverride = nil
        isDescendantOverride = nil
        trustedSurfaceScopeOverride = nil
        workingDirectoryOverride = nil
        auditLogURLOverride = nil
        CMUXSudoPendingRequestStore.shared.reset()
    }
}
#endif
