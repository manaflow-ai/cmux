import AppKit
import GhosttyKit
import Testing

@testable import CmuxTerminal

@MainActor
@Suite("Terminal pointer style state")
struct TerminalPointerStyleStateTests {
    @Test("OSC 22 changes the focused surface pointer")
    func appliesGhosttyPointerShape() {
        var state = TerminalPointerStyleState()

        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_POINTER))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("unsupported shapes preserve the current pointer")
    func unsupportedShapeKeepsCurrentPointer() {
        var state = TerminalPointerStyleState()
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_CROSSHAIR))

        let changed = state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_WAIT))

        #expect(!changed)
        #expect(state.effectiveCursor == NSCursor.crosshair)
    }

    @Test("focus loss temporarily restores the terminal default")
    func focusLossRestoresDefaultWithoutDiscardingSurfaceState() {
        var state = TerminalPointerStyleState()
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_POINTER))

        state.apply(.focusChanged(false))
        #expect(state.effectiveCursor == NSCursor.iBeam)

        state.apply(.focusChanged(true))
        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("terminal lifecycle reset discards a stale OSC 22 pointer")
    func lifecycleResetRestoresDefault() {
        var state = TerminalPointerStyleState()
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_GRABBING))

        state.apply(.reset)

        #expect(state.effectiveCursor == NSCursor.iBeam)
    }

    @Test("cmux link hover overrides OSC 22 and clears on focus loss")
    func linkHoverPrecedence() {
        var state = TerminalPointerStyleState()
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_CROSSHAIR))

        state.apply(.cmuxLinkHoverChanged(true))
        #expect(state.effectiveCursor == NSCursor.pointingHand)

        state.apply(.cmuxLinkHoverChanged(false))
        #expect(state.effectiveCursor == NSCursor.crosshair)

        state.apply(.cmuxLinkHoverChanged(true))
        state.apply(.focusChanged(false))
        state.apply(.focusChanged(true))
        #expect(state.effectiveCursor == NSCursor.crosshair)
    }

    @Test("pointer state is isolated between terminal surfaces")
    func stateDoesNotLeakBetweenSurfaces() {
        var firstSurface = TerminalPointerStyleState()
        var secondSurface = TerminalPointerStyleState()
        firstSurface.apply(.focusChanged(true))
        secondSurface.apply(.focusChanged(true))

        firstSurface.apply(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY))

        #expect(firstSurface.effectiveCursor == NSCursor.dragCopy)
        #expect(secondSurface.effectiveCursor == NSCursor.iBeam)
    }
}
