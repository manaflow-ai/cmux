import Foundation
@testable import CmuxControlSocket

// Benign defaults for the system-domain seam, so a test fake that conforms to
// the full `ControlCommandContext` umbrella only has to implement the domain
// it actually exercises (same pattern as ControlCommandContextTestStubs.swift;
// kept in its own file because that shared file is owned by another stage-3c
// agent).

extension ControlSystemContext {
    func controlSystemIdentify(params: [String: JSONValue]) -> JSONValue { .object([:]) }
    func controlSystemTreeWindows(
        requestedWindowID: UUID?,
        includeAllWindows: Bool,
        focusedWindowID: UUID?,
        workspaceFilter: UUID?
    ) -> ControlSystemTreeResolution {
        ControlSystemTreeResolution(
            windowFound: requestedWindowID == nil,
            workspaceFound: workspaceFilter == nil,
            windows: []
        )
    }
    func controlAuthPasswordRequired() -> Bool { false }
    func controlSessionRestorePrevious() -> ControlSessionRestoreResolution {
        .noSnapshot(message: "No previous session snapshot available")
    }
    func controlSettingsOpen(targetRaw: String?, requestedActivate: Bool) -> ControlSettingsOpenResolution {
        .opened(target: targetRaw ?? "general")
    }
    func controlFeedbackOpen(workspaceID: UUID?, windowID: UUID?, requestedActivate: Bool) {}
    func controlExtensionSidebarSnapshot(routing: ControlRoutingSelectors) -> ControlExtensionSidebarSnapshot? { nil }
    func controlWorkspaceAction(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "unavailable", message: "TabManager not available", data: nil)
    }
    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        titleSource: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution { .tabManagerUnavailable }
    func controlSurfaceSplitOff(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "unavailable", message: "AppDelegate not available", data: nil)
    }
    #if DEBUG
    func controlMobileDevStackAuthSetToken(_ token: String?) {}
    #endif
}
