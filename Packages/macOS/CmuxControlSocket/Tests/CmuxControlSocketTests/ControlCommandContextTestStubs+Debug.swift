import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the debug-domain seam, so a test fake that
// conforms to the full `ControlCommandContext` umbrella only has to implement
// the domain it actually exercises (the per-domain companion to the shared
// `ControlCommandContextTestStubs.swift`). The whole domain is DEBUG-only;
// release test builds see an empty extension, matching the empty protocol.

#if DEBUG
extension ControlDebugContext {
    func controlDebugSessionSnapshotBenchmark(includeScrollback: Bool, persist: Bool) -> JSONValue? { nil }
    func controlDebugSessionSnapshotSeedScrollback(charactersPerTerminal: Int) -> JSONValue? { nil }
    func controlDebugSetShortcut(arguments: String) -> String { "ERROR: not implemented" }
    func controlDebugSimulateShortcut(combo: String) -> String { "ERROR: not implemented" }
    func controlDebugActivateApp() -> String { "ERROR: not implemented" }
    func controlDebugRequestWorkspaceTodoChecklistAddField() -> UUID? { nil }
    func controlDebugIsTerminalFocused(surfaceArgument: String) -> String { "ERROR: not implemented" }
    func controlDebugReadTerminalText(surfaceArgument: String) -> String { "ERROR: not implemented" }
    func controlDebugRenderStats(surfaceArgument: String) -> String { "ERROR: not implemented" }
    func controlDebugLayout() -> String { "ERROR: not implemented" }
    func controlDebugBonsplitUnderflowCount() -> String { "ERROR: not implemented" }
    func controlDebugResetBonsplitUnderflowCount() -> String { "ERROR: not implemented" }
    func controlDebugEmptyPanelCount() -> String { "ERROR: not implemented" }
    func controlDebugResetEmptyPanelCount() -> String { "ERROR: not implemented" }
    func controlDebugFocusNotification(arguments: String) -> String { "ERROR: not implemented" }
    func controlDebugFlashCount(surfaceArgument: String) -> String { "ERROR: not implemented" }
    func controlDebugResetFlashCounts() -> String { "ERROR: not implemented" }
    func controlDebugPanelSnapshot(arguments: String) -> String { "ERROR: not implemented" }
    func controlDebugPanelSnapshotReset(surfaceArgument: String) -> String { "ERROR: not implemented" }
    func controlDebugCaptureScreenshot(label: String) -> String { "ERROR: not implemented" }
    func controlDebugShowCanvasCommandScrollHint(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlDebugTypeText(_ text: String) -> ControlDebugTypeResolution { .noWindow }
    func controlDebugTabManagerAvailable() -> Bool { false }
    func controlDebugTextBoxInlineFixture(
        target: String?,
        path: String?,
        beforeText: String,
        afterText: String
    ) -> ControlDebugTextBoxFixtureSnapshot? { nil }
    func controlDebugTextBoxInteract(target: String?, action: String) -> ControlDebugTextBoxInteraction? { nil }
    func controlDebugPostCommandPaletteEvent(_ event: ControlDebugCommandPaletteEvent, windowID: UUID?) -> Bool { false }
    func controlDebugCommandPaletteVisible(windowID: UUID) -> Bool { false }
    func controlDebugCommandPaletteSelectionIndex(windowID: UUID) -> Int { 0 }
    func controlDebugCommandPaletteSnapshot(windowID: UUID) -> ControlDebugCommandPaletteSnapshot { .empty }
    func controlDebugCommandPaletteRenameInputSelection(
        windowID: UUID
    ) -> ControlDebugRenameInputSelectionResolution { .windowNotFound }
    func controlDebugCommandPaletteRenameSelectAll(updating enabled: Bool?) -> Bool { false }
    func controlDebugFocusedBrowserAddressBarSurfaceID() -> UUID? { nil }
    func controlDebugBrowserFavicon(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "unavailable", message: "not implemented", data: nil)
    }
    func controlDebugRightSidebarFocus(
        modeName: String?,
        windowID: UUID?,
        focusFirstItem: Bool
    ) -> ControlDebugRightSidebarFocusResolution { .windowNotFound }
    func controlDebugSidebarVisibility(windowID: UUID) -> Bool? { nil }
    func controlDebugSimulateTerminalFileDrop(
        surfaceArgument: String,
        paths: [String],
        route: ControlDebugFileDropRoute,
        payloadKind: ControlDebugFileDropPayloadKind
    ) -> ControlDebugFileDropResolution { .panelNotFound }
    func controlDebugPortalStats() -> JSONValue? { nil }
}
#endif
