import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalKeyboardDockEndpoints keyboard-leg arithmetic")
struct TerminalKeyboardDockEndpointsTests {
    @Test("keyboard rise reserves the overlap and rides the render with the dock")
    func keyboardRise() {
        // 874pt phone, 336pt keyboard, full-height render whose settled pin
        // rides the new viewport bottom (cursor at the bottom row).
        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: 874,
            bottomReservation: 336,
            settledRenderBottom: 874 - 336 - 80,
            modelRenderBottom: 874 - 34 - 80
        )
        #expect(endpoints.dockBottomConstant == -336)
        #expect(endpoints.keyboardTopTarget == 538)
        // The render travels exactly the dock's extra travel (336 - 34 = 302),
        // so the content stays glued to the bars on every animation frame.
        #expect(endpoints.presentationBottomConstant == -302)
    }

    @Test("keyboard dismissal that holds the top row does not move the render")
    func dismissalHoldsRender() {
        // Settled pin equals the current model bottom: the top row stays put
        // and the departing keyboard reveals rows below (they arrive with the
        // grid echo). The wrapper offset must be exactly zero — any other
        // value would translate the frozen render mid-flight.
        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: 874,
            bottomReservation: 34,
            settledRenderBottom: 458,
            modelRenderBottom: 458
        )
        #expect(endpoints.presentationBottomConstant == 0)
        #expect(endpoints.keyboardTopTarget == 840)
    }

    @Test("blank rows absorbing the keyboard intrusion move the render only partially")
    func cursorAbsorbedRise() {
        // Sparse prompt: the cursor-aware settled pin holds the render 200pt
        // above the new viewport bottom because blank rows absorb the
        // intrusion. The wrapper carries only the partial travel.
        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: 874,
            bottomReservation: 336,
            settledRenderBottom: 640,
            modelRenderBottom: 760
        )
        #expect(endpoints.presentationBottomConstant == -120)
        #expect(endpoints.settledRenderBottom == 640)
    }

    @Test("negative reservation clamps to zero and cannot push the dock below the host")
    func reservationClamp() {
        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: 874,
            bottomReservation: -10,
            settledRenderBottom: 874,
            modelRenderBottom: 874
        )
        #expect(endpoints.dockBottomConstant == 0)
        #expect(endpoints.keyboardTopTarget == 874)
    }

    @Test("keyboard taller than the host floors the keyboard-top target at zero")
    func oversizedKeyboard() {
        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: 300,
            bottomReservation: 400,
            settledRenderBottom: 0,
            modelRenderBottom: 100
        )
        #expect(endpoints.keyboardTopTarget == 0)
        #expect(endpoints.dockBottomConstant == -400)
    }
}
