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

        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("repeated OSC 22 shape does not invalidate cursor rects")
    func repeatedGhosttyPointerShapeIsUnchanged() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))

        let firstChange = state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        let repeatedChange = state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        if #available(macOS 15.0, *) {
            #expect(firstChange)
            #expect(!repeatedChange)
        } else {
            #expect(!firstChange)
            #expect(!repeatedChange)
        }
    }

    @Test("OSC 22 shapes map to their closest public AppKit cursor")
    func mapsSupportedGhosttyPointerShapes() {
        var mappings: [(ghostty_action_mouse_shape_e, NSCursor)] = [
            (GHOSTTY_MOUSE_SHAPE_DEFAULT, .arrow),
            (GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU, .contextualMenu),
            (GHOSTTY_MOUSE_SHAPE_POINTER, .pointingHand),
            (GHOSTTY_MOUSE_SHAPE_CELL, .crosshair),
            (GHOSTTY_MOUSE_SHAPE_CROSSHAIR, .crosshair),
            (GHOSTTY_MOUSE_SHAPE_TEXT, .iBeam),
            (GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT, .iBeamCursorForVerticalLayout),
            (GHOSTTY_MOUSE_SHAPE_ALIAS, .dragLink),
            (GHOSTTY_MOUSE_SHAPE_COPY, .dragCopy),
            (GHOSTTY_MOUSE_SHAPE_MOVE, .openHand),
            (GHOSTTY_MOUSE_SHAPE_ALL_SCROLL, .openHand),
            (GHOSTTY_MOUSE_SHAPE_GRAB, .openHand),
            (GHOSTTY_MOUSE_SHAPE_GRABBING, .closedHand),
            (GHOSTTY_MOUSE_SHAPE_NO_DROP, .operationNotAllowed),
            (GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, .operationNotAllowed),
        ]

        if #available(macOS 15.0, *) {
            mappings += [
                (GHOSTTY_MOUSE_SHAPE_COL_RESIZE, .columnResize),
                (GHOSTTY_MOUSE_SHAPE_EW_RESIZE, .columnResize),
                (GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, .rowResize),
                (GHOSTTY_MOUSE_SHAPE_NS_RESIZE, .rowResize),
                (
                    GHOSTTY_MOUSE_SHAPE_N_RESIZE,
                    .rowResize(directions: .up)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_E_RESIZE,
                    .columnResize(directions: .right)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_S_RESIZE,
                    .rowResize(directions: .down)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_W_RESIZE,
                    .columnResize(directions: .left)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
                    .frameResize(position: .topRight, directions: .outward)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
                    .frameResize(position: .topRight, directions: .all)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
                    .frameResize(position: .topLeft, directions: .outward)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
                    .frameResize(position: .topLeft, directions: .all)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
                    .frameResize(position: .bottomRight, directions: .outward)
                ),
                (
                    GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
                    .frameResize(position: .bottomLeft, directions: .outward)
                ),
                (GHOSTTY_MOUSE_SHAPE_ZOOM_IN, .zoomIn),
                (GHOSTTY_MOUSE_SHAPE_ZOOM_OUT, .zoomOut),
            ]
        } else {
            mappings += [
                (GHOSTTY_MOUSE_SHAPE_COL_RESIZE, .resizeLeftRight),
                (GHOSTTY_MOUSE_SHAPE_EW_RESIZE, .resizeLeftRight),
                (GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, .resizeUpDown),
                (GHOSTTY_MOUSE_SHAPE_NS_RESIZE, .resizeUpDown),
                (GHOSTTY_MOUSE_SHAPE_N_RESIZE, .resizeUp),
                (GHOSTTY_MOUSE_SHAPE_E_RESIZE, .resizeRight),
                (GHOSTTY_MOUSE_SHAPE_S_RESIZE, .resizeDown),
                (GHOSTTY_MOUSE_SHAPE_W_RESIZE, .resizeLeft),
            ]
        }

        for (shape, expected) in mappings {
            var state = TerminalPointerStyleState()
            let runtimeLifetimeId = activate(&state)
            state.apply(.focusChanged(true))
            state.apply(.ghosttyShape(
                shape,
                runtimeLifetimeId: runtimeLifetimeId
            ))

            #expect(state.effectiveCursor.isEqual(expected))
        }
    }

    @Test("shapes without a public AppKit equivalent preserve the current pointer")
    func unsupportedGhosttyPointerShapesPreserveCurrentPointer() {
        var shapes = [
            GHOSTTY_MOUSE_SHAPE_HELP,
            GHOSTTY_MOUSE_SHAPE_PROGRESS,
            GHOSTTY_MOUSE_SHAPE_WAIT,
        ]
        if #unavailable(macOS 15.0) {
            shapes += [
                GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
                GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
                GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
                GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
                GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
                GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
                GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
                GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
            ]
        }

        for shape in shapes {
            var state = TerminalPointerStyleState()
            let runtimeLifetimeId = activate(&state)
            state.apply(.focusChanged(true))
            state.apply(.ghosttyShape(
                GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
                runtimeLifetimeId: runtimeLifetimeId
            ))

            let changed = state.apply(.ghosttyShape(
                shape,
                runtimeLifetimeId: runtimeLifetimeId
            ))

            #expect(!changed)
            #expect(state.effectiveCursor == NSCursor.crosshair)
        }
    }

    @Test("unsupported base shapes do not erase persistent OSC 22 pointer")
    func unsupportedBaseDoesNotErasePersistentPointer() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_HELP,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("unsupported link bases restore after an unfocused hover")
    func unsupportedLinkBaseRestoresAfterUnfocusedHover() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.focusChanged(false))
        state.apply(.ghosttyLinkHoverChanged(
            true,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_HELP,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.focusChanged(true))

        #expect(state.effectiveCursor == NSCursor.crosshair)
    }

    @Test("focus loss temporarily restores the terminal default")
    func focusLossRestoresDefaultWithoutDiscardingSurfaceState() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.focusChanged(false))
        #expect(state.effectiveCursor == NSCursor.iBeam)

        state.apply(.focusChanged(true))
        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("terminal runtime end discards a stale OSC 22 pointer")
    func runtimeEndRestoresDefault() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_GRABBING,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.runtimeEnded(runtimeLifetimeId))

        #expect(state.effectiveCursor == NSCursor.iBeam)
    }

    @Test("child exit resets pointer intent without ending the runtime")
    func childExitResetsPointerIntentWithoutEndingRuntime() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.runtimeReset(runtimeLifetimeId))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.crosshair)
    }

    @Test("hyperlink hover restores an unsupported OSC 22 base shape")
    func hyperlinkHoverRestoresUnsupportedBaseShape() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_HELP,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            true,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        #expect(state.effectiveCursor == NSCursor.pointingHand)

        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_HELP,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.iBeam)
    }

    @Test("empty hyperlink exit without a base shape preserves pointer intent")
    func emptyHyperlinkExitWithoutBaseShapePreservesPointerIntent() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_HELP,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("hyperlink hover preserves an explicit OSC 22 pointer base")
    func hyperlinkHoverPreservesPointerBaseShape() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            true,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("empty hyperlink exit preserves a persistent OSC 22 pointer")
    func emptyHyperlinkExitPreservesPersistentPointerBase() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.ghosttyLinkHoverChanged(
            false,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        #expect(state.effectiveCursor == NSCursor.pointingHand)
    }

    @Test("delayed hyperlink activation cannot survive focus loss")
    func delayedHyperlinkActivationIsClampedToFocus() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.focusChanged(false))
        state.apply(.ghosttyLinkHoverChanged(
            true,
            runtimeLifetimeId: runtimeLifetimeId
        ))
        state.apply(.focusChanged(true))

        #expect(state.effectiveCursor == NSCursor.crosshair)
    }

    @Test("stale runtime callbacks cannot mutate a replacement lifetime")
    func staleRuntimeCallbacksCannotMutateReplacementLifetime() {
        var state = TerminalPointerStyleState()
        let oldRuntimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: oldRuntimeLifetimeId
        ))

        let newRuntimeLifetimeId = activate(&state)
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_POINTER,
            runtimeLifetimeId: oldRuntimeLifetimeId
        ))
        state.apply(.runtimeEnded(oldRuntimeLifetimeId))

        #expect(state.effectiveCursor == NSCursor.iBeam)

        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_COPY,
            runtimeLifetimeId: newRuntimeLifetimeId
        ))
        #expect(state.effectiveCursor == NSCursor.dragCopy)
    }

    @Test("cmux link hover overrides OSC 22 without requiring terminal focus")
    func linkHoverPrecedence() {
        var state = TerminalPointerStyleState()
        let runtimeLifetimeId = activate(&state)
        state.apply(.focusChanged(true))
        state.apply(.ghosttyShape(
            GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
            runtimeLifetimeId: runtimeLifetimeId
        ))

        state.apply(.cmuxLinkHoverChanged(true))
        #expect(state.effectiveCursor == NSCursor.pointingHand)

        state.apply(.cmuxLinkHoverChanged(false))
        #expect(state.effectiveCursor == NSCursor.crosshair)

        state.apply(.cmuxLinkHoverChanged(true))
        state.apply(.focusChanged(false))
        #expect(state.effectiveCursor == NSCursor.pointingHand)

        state.apply(.cmuxLinkHoverChanged(false))
        #expect(state.effectiveCursor == NSCursor.iBeam)
    }

    private func activate(_ state: inout TerminalPointerStyleState) -> UUID {
        let runtimeLifetimeId = UUID()
        state.apply(.runtimeActivated(runtimeLifetimeId))
        return runtimeLifetimeId
    }
}
