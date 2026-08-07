import AppKit
import CmuxTerminalCore
@testable import CmuxTerminal

final class FakeTerminalSurfaceNativeView: NSView {
    var tabId: UUID?
    var hostedTabId: UUID? { tabId }
    weak var attachedController: (any TerminalSurfaceControlling)?
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { attachedController }
    var currentKeyStateIndicatorText: String? { nil }
    var isKeyboardCopyModeActive: Bool { false }
    var shouldDeferRuntimeInput = false
    var deferredRuntimeInputs: [() -> Void] = []
    var deferredRuntimeInputBytes: [Int] = []

    func toggleKeyboardCopyMode() -> Bool { false }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
    func runtimeSurfaceDidBecomeReady() {}

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool {
        guard shouldDeferRuntimeInput else { return false }
        deferredRuntimeInputBytes.append(estimatedBytes)
        deferredRuntimeInputs.append(replay)
        return true
    }
}

extension FakeTerminalSurfaceNativeView: @preconcurrency TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: TerminalSurfaceNativeViewing {}
