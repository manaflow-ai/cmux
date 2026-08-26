import AppKit
import CmuxTerminalCore
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalSurfaceNativeView: NSView {
    var tabId: UUID?
    var hostedTabId: UUID? { tabId }
    weak var attachedController: (any TerminalSurfaceControlling)?
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { attachedController }
    var currentKeyStateIndicatorText: String? { nil }
    var isKeyboardCopyModeActive = false
    private(set) var keyboardCopyModeCancellationCount = 0
    var shouldDeferRuntimeInput = false
    var runtimeInputDeferralResponses: [Bool] = []
    var runtimeInputDeferralCallCount = 0
    var deferredRuntimeInputs: [() -> Void] = []
    var deferredRuntimeInputBytes: [Int] = []
    var mobileMouseButtonEvents: [String] = []

    func toggleKeyboardCopyMode() -> Bool { false }
    func cancelKeyboardCopyMode() {
        keyboardCopyModeCancellationCount += 1
        isKeyboardCopyModeActive = false
    }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
    func runtimeSurfaceDidBecomeReady() {}

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool {
        runtimeInputDeferralCallCount += 1
        let shouldDefer = runtimeInputDeferralResponses.isEmpty
            ? shouldDeferRuntimeInput
            : runtimeInputDeferralResponses.removeFirst()
        guard shouldDefer else { return false }
        deferredRuntimeInputBytes.append(estimatedBytes)
        deferredRuntimeInputs.append(replay)
        return true
    }

    func positionMobilePointer(
        on _: ghostty_surface_t,
        column _: Int,
        row _: Int,
        contentScale _: CGFloat
    ) {}

    func sendMobileMouseButton(
        _ state: ghostty_input_mouse_state_e,
        on _: ghostty_surface_t
    ) {
        mobileMouseButtonEvents.append(
            state == GHOSTTY_MOUSE_PRESS ? "press" : "release"
        )
    }
}

extension FakeTerminalSurfaceNativeView: @preconcurrency TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: TerminalSurfaceNativeViewing {}
