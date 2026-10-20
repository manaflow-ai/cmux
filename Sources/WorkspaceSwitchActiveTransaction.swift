import Foundation

/// Mutable request-scoped diagnostics and cleanup ownership for one switch.
struct WorkspaceSwitchActiveTransaction {
    let requestID: UUID
    var sourceWorkspaceID: UUID
    let targetWorkspaceID: UUID
    var targetSurfaceID: UUID?
    var targetTerminalViewID: ObjectIdentifier?
    var targetWebViewID: ObjectIdentifier?
    var readiness: WorkspaceSwitchReadiness?
    var sourceRetired = false
    var rendererProtectionActive = false
    var warmFrameAvailable = false
    var frameSequenceAtSelection: UInt64 = 0
    var observedFrameAfterSelection = false
    var frameObservation: WorkspaceSwitchFrameObservation?
    var selectionCommitInterval: DynamicTracingSignpostInterval?
    var portalShowInterval: DynamicTracingSignpostInterval?
    var portalHideInterval: DynamicTracingSignpostInterval?
    var rendererRealizationInterval: DynamicTracingSignpostInterval?
    var firstFrameInterval: DynamicTracingSignpostInterval?
    var interactiveInterval: DynamicTracingSignpostInterval?
}
