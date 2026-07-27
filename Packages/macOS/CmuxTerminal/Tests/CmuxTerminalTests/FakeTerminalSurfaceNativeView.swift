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

    func toggleKeyboardCopyMode() -> Bool { false }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
}

extension FakeTerminalSurfaceNativeView: @preconcurrency TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: TerminalSurfaceNativeViewing {}
