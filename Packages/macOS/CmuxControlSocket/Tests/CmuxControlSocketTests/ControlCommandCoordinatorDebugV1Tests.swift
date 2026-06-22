import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
/// A scriptable ``ControlDebugContext`` for driving the v1 debug dispatch
/// without the app target. Only the debug methods the v1 dispatch exercises are
/// overridden; the rest fall back to the benign defaults in
/// `ControlCommandContextTestStubs+Debug.swift`.
@MainActor
private final class FakeDebugV1ControlCommandContext: ControlCommandContext {
    var setShortcutArguments: String?
    var setShortcutResponse = "OK"

    var rightSidebarMode: String??
    var rightSidebarFocusFirstItem: Bool?
    var rightSidebarResolution: ControlDebugRightSidebarFocusResolution = .windowNotFound

    var seedDragArguments: String?
    var seedDragResponse = "OK"

    var overlayDropGateHasLocalDraggingSource: Bool?
    var overlayDropGateResult = false

    var sidebarOverlayGateHasSidebarDragState: Bool?
    var sidebarOverlayGateResult = false

    var terminalDropOverlayProbeUseDeferredPath: Bool?
    var terminalDropOverlayProbeResolution: ControlDebugTerminalDropOverlayProbeResolution = .noWorkspace

    var dropHitTestPoint: (nx: Double, ny: Double)?
    var dropHitTestResult = "none"

    var dragHitChainPoint: (nx: Double, ny: Double)?
    var dragHitChainResult = "none"

    var overlayHitGateEventToken: ControlDebugOverlayEventToken?
    var overlayHitGateResult = false

    var portalHitGateEventToken: ControlDebugOverlayEventToken?
    var portalHitGateResult = false

    func controlDebugOverlayHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        overlayHitGateEventToken = eventToken
        return overlayHitGateResult
    }

    func controlDebugPortalHitGate(eventToken: ControlDebugOverlayEventToken) -> Bool {
        portalHitGateEventToken = eventToken
        return portalHitGateResult
    }

    func controlDebugSetShortcut(arguments: String) -> String {
        setShortcutArguments = arguments
        return setShortcutResponse
    }

    func controlDebugOverlayDropGate(hasLocalDraggingSource: Bool) -> Bool {
        overlayDropGateHasLocalDraggingSource = hasLocalDraggingSource
        return overlayDropGateResult
    }

    func controlDebugSidebarOverlayGate(hasSidebarDragState: Bool) -> Bool {
        sidebarOverlayGateHasSidebarDragState = hasSidebarDragState
        return sidebarOverlayGateResult
    }

    func controlDebugTerminalDropOverlayProbe(
        useDeferredPath: Bool
    ) -> ControlDebugTerminalDropOverlayProbeResolution {
        terminalDropOverlayProbeUseDeferredPath = useDeferredPath
        return terminalDropOverlayProbeResolution
    }

    func controlDebugDropHitTest(nx: Double, ny: Double) -> String {
        dropHitTestPoint = (nx, ny)
        return dropHitTestResult
    }

    func controlDebugDragHitChain(nx: Double, ny: Double) -> String {
        dragHitChainPoint = (nx, ny)
        return dragHitChainResult
    }

    func controlDebugSeedDragPasteboardTypes(arguments: String) -> String {
        seedDragArguments = arguments
        return seedDragResponse
    }

    func controlDebugRightSidebarFocus(
        modeName: String?,
        windowID: UUID?,
        focusFirstItem: Bool
    ) -> ControlDebugRightSidebarFocusResolution {
        rightSidebarMode = modeName
        rightSidebarFocusFirstItem = focusFirstItem
        return rightSidebarResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug v1 dispatch")
struct ControlCommandCoordinatorDebugV1Tests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugV1ControlCommandContext) {
        let context = FakeDebugV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    @Test func forwardsSetShortcutArgumentsVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "open-palette cmd+k")
        #expect(reply == "OK")
        #expect(context.setShortcutArguments == "open-palette cmd+k")
    }

    @Test func forwardsSetShortcutErrorVerbatim() {
        let (coordinator, context) = makeCoordinator()
        context.setShortcutResponse = "ERROR: Invalid shortcut"
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "x")
        #expect(reply == "ERROR: Invalid shortcut")
    }

    @Test func unknownCommandFallsThrough() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleDebugV1(command: "ping", args: "") == nil)
        #expect(coordinator.handleDebugV1(command: "list_windows", args: "") == nil)
    }

    @Test func seedDragPasteboardAliasesPassFixedTypeTokens() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handleDebugV1(command: "seed_drag_pasteboard_fileurl", args: "") == "OK")
        #expect(context.seedDragArguments == "fileurl")
        #expect(coordinator.handleDebugV1(command: "seed_drag_pasteboard_tabtransfer", args: "") == "OK")
        #expect(context.seedDragArguments == "tabtransfer")
        #expect(coordinator.handleDebugV1(command: "seed_drag_pasteboard_sidebar_reorder", args: "") == "OK")
        #expect(context.seedDragArguments == "sidebarreorder")
    }

    @Test func seedDragPasteboardTypesForwardsRawArguments() {
        let (coordinator, context) = makeCoordinator()
        context.seedDragResponse = "ERROR: Unknown drag type 'x'"
        let reply = coordinator.handleDebugV1(command: "seed_drag_pasteboard_types", args: "x")
        #expect(reply == "ERROR: Unknown drag type 'x'")
        #expect(context.seedDragArguments == "x")
    }

    @Test func rightSidebarFocusInvalidModeReproducesLegacyString() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .invalidMode("bogus")
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "  bogus  ")
        // The v1 body trims the mode argument before validating.
        #expect(context.rightSidebarMode == .some("bogus"))
        // The v1 body never focuses the first item.
        #expect(context.rightSidebarFocusFirstItem == false)
        #expect(reply == "ERROR: Invalid right sidebar mode: bogus")
    }

    @Test func rightSidebarFocusEmptyArgsPassesNilModeForDockDefault() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .revealed(ControlDebugRightSidebarFocusState(
            revealed: true,
            focusApplied: false,
            contextFound: true,
            stateFound: true,
            visible: true,
            activeMode: "dock",
            mode: "dock"
        ))
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "   ")
        // Empty argument maps to nil so the app resolves its `dock` default.
        #expect(context.rightSidebarMode == .some(nil))
        #expect(reply == "OK: mode=dock active=dock visible=1 context=1 state=1 focus=0")
    }

    @Test func rightSidebarFocusUnrevealedReproducesLegacyErrorString() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .revealed(ControlDebugRightSidebarFocusState(
            revealed: false,
            focusApplied: false,
            contextFound: false,
            stateFound: false,
            visible: false,
            activeMode: nil,
            mode: "split"
        ))
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "split")
        #expect(reply == "ERROR: mode=split active= visible=0 context=0 state=0 focus=0")
    }

    // MARK: - overlay_drop_gate

    @Test func overlayDropGateParsesTokensAndFormatsBool() {
        let (coordinator, context) = makeCoordinator()
        context.overlayDropGateResult = true
        #expect(coordinator.handleDebugV1(command: "overlay_drop_gate", args: "") == "true")
        #expect(context.overlayDropGateHasLocalDraggingSource == false)
        #expect(coordinator.handleDebugV1(command: "overlay_drop_gate", args: "external") == "true")
        #expect(context.overlayDropGateHasLocalDraggingSource == false)
        context.overlayDropGateResult = false
        #expect(coordinator.handleDebugV1(command: "overlay_drop_gate", args: "LOCAL") == "false")
        #expect(context.overlayDropGateHasLocalDraggingSource == true)
    }

    @Test func overlayDropGateRejectsUnknownTokenWithUsage() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "overlay_drop_gate", args: "bogus")
        #expect(reply == "ERROR: Usage: overlay_drop_gate [external|local]")
        // The live read is never invoked on a parse failure.
        #expect(context.overlayDropGateHasLocalDraggingSource == nil)
    }

    // MARK: - sidebar_overlay_gate

    @Test func sidebarOverlayGateParsesTokensAndFormatsBool() {
        let (coordinator, context) = makeCoordinator()
        context.sidebarOverlayGateResult = true
        #expect(coordinator.handleDebugV1(command: "sidebar_overlay_gate", args: "") == "true")
        #expect(context.sidebarOverlayGateHasSidebarDragState == true)
        #expect(coordinator.handleDebugV1(command: "sidebar_overlay_gate", args: "active") == "true")
        #expect(context.sidebarOverlayGateHasSidebarDragState == true)
        context.sidebarOverlayGateResult = false
        #expect(coordinator.handleDebugV1(command: "sidebar_overlay_gate", args: "Inactive") == "false")
        #expect(context.sidebarOverlayGateHasSidebarDragState == false)
    }

    @Test func sidebarOverlayGateRejectsUnknownTokenWithUsage() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "sidebar_overlay_gate", args: "bogus")
        #expect(reply == "ERROR: Usage: sidebar_overlay_gate [active|inactive]")
        #expect(context.sidebarOverlayGateHasSidebarDragState == nil)
    }

    // MARK: - terminal_drop_overlay_probe

    @Test func terminalDropOverlayProbeFormatsSuccessLine() {
        let (coordinator, context) = makeCoordinator()
        context.terminalDropOverlayProbeResolution = .probed(
            before: 1,
            after: 3,
            boundsWidth: 120.56,
            boundsHeight: 80.0
        )
        let reply = coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "")
        #expect(context.terminalDropOverlayProbeUseDeferredPath == true)
        // animated = after(3) > before(1); bounds use %.1f (120.56 → 120.6);
        // default token = deferred. Identical to the legacy String(format:).
        #expect(reply == "OK mode=deferred animated=1 before=1 after=3 bounds=120.6x80.0")
    }

    @Test func terminalDropOverlayProbeDirectTokenAndNotAnimated() {
        let (coordinator, context) = makeCoordinator()
        context.terminalDropOverlayProbeResolution = .probed(
            before: 2,
            after: 2,
            boundsWidth: 10,
            boundsHeight: 20
        )
        let reply = coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "direct")
        #expect(context.terminalDropOverlayProbeUseDeferredPath == false)
        #expect(reply == "OK mode=direct animated=0 before=2 after=2 bounds=10.0x20.0")
    }

    @Test func terminalDropOverlayProbeMapsLiveErrorResolutions() {
        let (coordinator, context) = makeCoordinator()
        context.terminalDropOverlayProbeResolution = .tabManagerUnavailable
        #expect(coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "") == "ERROR: TabManager not available")
        context.terminalDropOverlayProbeResolution = .noWorkspace
        #expect(coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "") == "ERROR: No selected workspace")
        context.terminalDropOverlayProbeResolution = .noPanel
        #expect(coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "") == "ERROR: No terminal panel available")
    }

    @Test func terminalDropOverlayProbeRejectsUnknownTokenWithUsage() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "terminal_drop_overlay_probe", args: "bogus")
        #expect(reply == "ERROR: Usage: terminal_drop_overlay_probe [deferred|direct]")
        #expect(context.terminalDropOverlayProbeUseDeferredPath == nil)
    }

    // MARK: - drop_hit_test / drag_hit_chain (shared coordinate parse)

    @Test func dropHitTestParsesValidCoordinatesAndForwards() {
        let (coordinator, context) = makeCoordinator()
        context.dropHitTestResult = "ABC-123"
        let reply = coordinator.handleDebugV1(command: "drop_hit_test", args: "0.25 0.75")
        #expect(reply == "ABC-123")
        #expect(context.dropHitTestPoint?.nx == 0.25)
        #expect(context.dropHitTestPoint?.ny == 0.75)
    }

    @Test func dropHitTestRejectsMalformedCoordinatesWithUsage() {
        let (coordinator, context) = makeCoordinator()
        // Wrong field count, out-of-range, and non-numeric all hit the usage line.
        #expect(coordinator.handleDebugV1(command: "drop_hit_test", args: "0.5") == "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>")
        #expect(coordinator.handleDebugV1(command: "drop_hit_test", args: "1.5 0.5") == "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>")
        #expect(coordinator.handleDebugV1(command: "drop_hit_test", args: "a b") == "ERROR: Usage: drop_hit_test <x 0-1> <y 0-1>")
        #expect(context.dropHitTestPoint == nil)
    }

    @Test func dragHitChainParsesValidCoordinatesAndForwards() {
        let (coordinator, context) = makeCoordinator()
        context.dragHitChainResult = "A->B->C"
        let reply = coordinator.handleDebugV1(command: "drag_hit_chain", args: "0 1")
        #expect(reply == "A->B->C")
        #expect(context.dragHitChainPoint?.nx == 0)
        #expect(context.dragHitChainPoint?.ny == 1)
    }

    @Test func dragHitChainRejectsMalformedCoordinatesWithUsage() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handleDebugV1(command: "drag_hit_chain", args: "0.5 0.5 0.5") == "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>")
        #expect(context.dragHitChainPoint == nil)
    }

    // MARK: - overlay_hit_gate / portal_hit_gate (shared event-token parse)

    private static let eventGateUsage = "<leftMouseDragged|rightMouseDragged|otherMouseDragged|mouseMoved|mouseEntered|mouseExited|flagsChanged|cursorUpdate|appKitDefined|systemDefined|applicationDefined|periodic|leftMouseDown|leftMouseUp|rightMouseDown|rightMouseUp|otherMouseDown|otherMouseUp|scrollWheel|none>"

    @Test func overlayHitGateParsesTokenAndFormatsBool() {
        let (coordinator, context) = makeCoordinator()
        context.overlayHitGateResult = true
        // Case-insensitive parse + the `mousemove` alias resolve to the typed token.
        #expect(coordinator.handleDebugV1(command: "overlay_hit_gate", args: "LeftMouseDragged") == "true")
        #expect(context.overlayHitGateEventToken == .leftMouseDragged)
        #expect(coordinator.handleDebugV1(command: "overlay_hit_gate", args: "mousemove") == "true")
        #expect(context.overlayHitGateEventToken == .mouseMoved)
        context.overlayHitGateResult = false
        #expect(coordinator.handleDebugV1(command: "overlay_hit_gate", args: "none") == "false")
        #expect(context.overlayHitGateEventToken == ControlDebugOverlayEventToken.none)
    }

    @Test func overlayHitGateEmptyTokenReturnsUsage() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "overlay_hit_gate", args: "")
        #expect(reply == "ERROR: Usage: overlay_hit_gate \(Self.eventGateUsage)")
        #expect(context.overlayHitGateEventToken == nil)
    }

    @Test func overlayHitGateUnknownTokenEchoesTrimmedArgument() {
        let (coordinator, context) = makeCoordinator()
        // The unknown-token error echoes the trimmed, original-case argument.
        let reply = coordinator.handleDebugV1(command: "overlay_hit_gate", args: "  Bogus  ")
        #expect(reply == "ERROR: Unknown event type 'Bogus'")
        #expect(context.overlayHitGateEventToken == nil)
    }

    @Test func portalHitGateParsesTokenAndFormatsBool() {
        let (coordinator, context) = makeCoordinator()
        context.portalHitGateResult = true
        #expect(coordinator.handleDebugV1(command: "portal_hit_gate", args: "scrollWheel") == "true")
        #expect(context.portalHitGateEventToken == .scrollWheel)
        context.portalHitGateResult = false
        #expect(coordinator.handleDebugV1(command: "portal_hit_gate", args: "flagsChanged") == "false")
        #expect(context.portalHitGateEventToken == .flagsChanged)
    }

    @Test func portalHitGateEmptyTokenReturnsUsage() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "portal_hit_gate", args: "  ")
        #expect(reply == "ERROR: Usage: portal_hit_gate \(Self.eventGateUsage)")
        #expect(context.portalHitGateEventToken == nil)
    }

    @Test func portalHitGateUnknownTokenEchoesTrimmedArgument() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "portal_hit_gate", args: "wat")
        #expect(reply == "ERROR: Unknown event type 'wat'")
        #expect(context.portalHitGateEventToken == nil)
    }
}
#endif
