#if canImport(UIKit)
import CoreGraphics
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The alternate-screen grid is resized only from a committed keyboard
/// height. Its viewport is then translated inside the full-height surface so
/// the bottom edge stays at the same dock seam as the keyboard-independent
/// layout.
struct TerminalAlternateScreenViewportTests {
    private func snapshot(height: CGFloat, keyboard: CGFloat = 0) -> TerminalViewportSnapshot {
        TerminalViewportCoordinator().snapshot(inputs: TerminalViewportInputs(
            bounds: CGSize(width: 402, height: height),
            keyboardHeight: keyboard,
            gridKeyboardHeight: keyboard,
            composerBandHeight: 0,
            reservedToolbarHeight: 44,
            toolbarFrameHeight: 44,
            bottomSafeAreaInset: 34,
            chromeHidden: false,
            topContentInset: 24
        ))
    }

    @Test("keyboard and rotation transitions retain the committed capacity")
    func transitionHoldsCapacity() {
        var fence = TerminalViewportGeometryFence()
        let portrait = snapshot(height: 874)
        let keyboard = snapshot(height: 874, keyboard: 300)
        let landscape = snapshot(height: 402, keyboard: 160)
        let initialCapacity = fence.snapshotForApply(portrait)
        #expect(initialCapacity == portrait)
        for _ in 0..<20 {
            let duringTransition = fence.sample(keyboard, transitionActive: true)
            #expect(!duringTransition)
        }
        let heldKeyboardCapacity = fence.snapshotForApply(keyboard)
        #expect(heldKeyboardCapacity == portrait)
        // Rotation overlaps the keyboard leg; no earlier candidate can commit.
        let duringRotation = fence.sample(landscape, transitionActive: true)
        #expect(!duringRotation)
        let firstSettledFrame = fence.sample(landscape, transitionActive: false)
        #expect(!firstSettledFrame)
        let secondSettledFrame = fence.sample(landscape, transitionActive: false)
        #expect(!secondSettledFrame)
        let thirdSettledFrame = fence.sample(landscape, transitionActive: false)
        #expect(thirdSettledFrame)
        let rotatedCapacity = fence.snapshotForApply(landscape)
        #expect(rotatedCapacity == landscape)
    }

    @Test("a reversed keyboard or interrupted window resize replaces its candidate")
    func changingCandidateRestartsFence() {
        var fence = TerminalViewportGeometryFence()
        let initial = snapshot(height: 874)
        let intermediate = snapshot(height: 700, keyboard: 300)
        let final = snapshot(height: 650)
        _ = fence.snapshotForApply(initial)
        let firstIntermediateFrame = fence.sample(intermediate, transitionActive: false)
        #expect(!firstIntermediateFrame)
        let secondIntermediateFrame = fence.sample(intermediate, transitionActive: false)
        #expect(!secondIntermediateFrame)
        let firstFinalFrame = fence.sample(final, transitionActive: false)
        #expect(!firstFinalFrame)
        let heldCapacity = fence.snapshotForApply(final)
        #expect(heldCapacity == initial)
        let secondFinalFrame = fence.sample(final, transitionActive: false)
        #expect(!secondFinalFrame)
        let thirdFinalFrame = fence.sample(final, transitionActive: false)
        #expect(thirdFinalFrame)
        #expect(fence.committed == final)
    }

    @MainActor
    @Test("alternate-screen keyboard sizing commits after completion and opt-out restores full height")
    func surfaceCommitsAfterKeyboardCompletion() throws {
        let delegate = AlternateScreenViewportDelegate()
        let view = GhosttySurfaceView(runtime: try GhosttyRuntime.shared(), delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        view.setTopContentInset(24)
        view.hostedAltScreenActive = true
        let fullHeight = view.terminalViewportRect.height
        view.setHostedKeyboardTransitionActive(true)
        view.setHostedKeyboardState(height: 300, isVisible: true)
        #expect(view.terminalViewportRect.height == fullHeight)
        view.setHostedKeyboardTransitionActive(false)
        #expect(view.terminalViewportRect.height == fullHeight - 300)
        #expect(view.hostedScrollTopRevealBudget == 0)
        view.useLegacyTerminalSizing = true
        #expect(view.terminalViewportRect.height == fullHeight)
        #expect(view.hostedScrollTopRevealBudget == 300)
        view.useLegacyTerminalSizing = false
        view.hostedAltScreenActive = false
        #expect(view.terminalViewportRect.height == fullHeight)
    }

    @Test("settled keyboard shortens the grid and keeps its bottom at the dock seam")
    func settledKeyboardMovesGridInsideSurface() {
        let coordinator = TerminalViewportCoordinator()
        let snapshot = coordinator.snapshot(inputs: TerminalViewportInputs(
            bounds: CGSize(width: 402, height: 874),
            keyboardHeight: 300,
            gridKeyboardHeight: 300,
            composerBandHeight: 120,
            reservedToolbarHeight: 44,
            toolbarFrameHeight: 44,
            bottomSafeAreaInset: 34,
            chromeHidden: false,
            topContentInset: 24
        ))

        #expect(snapshot.containerSize.height == 378)
        #expect(snapshot.layoutViewportRect.minY == 290)
        #expect(snapshot.layoutViewportRect.maxY == 668)
        #expect(snapshot.layoutViewportRect.maxY == CGFloat(874 - 34 - 120 - 44 - 8))
    }

    @Test("zero grid keyboard height preserves the primary-screen layout")
    func zeroGridKeyboardHeightKeepsLegacyLayout() {
        let coordinator = TerminalViewportCoordinator()
        let snapshot = coordinator.snapshot(inputs: TerminalViewportInputs(
            bounds: CGSize(width: 402, height: 874),
            keyboardHeight: 300,
            gridKeyboardHeight: 0,
            composerBandHeight: 120,
            reservedToolbarHeight: 44,
            toolbarFrameHeight: 44,
            bottomSafeAreaInset: 34,
            chromeHidden: false,
            topContentInset: 24
        ))

        #expect(snapshot.containerSize.height == 644)
        #expect(snapshot.layoutViewportRect.minY == 24)
        #expect(snapshot.layoutViewportRect.maxY == 668)
    }
}
@MainActor
private final class AlternateScreenViewportDelegate: NSObject, GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {}
}
#endif
