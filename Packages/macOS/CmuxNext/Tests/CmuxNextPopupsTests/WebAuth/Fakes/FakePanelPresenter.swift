import AppKit
import CmuxNextDesign

/// Records each panel a sign-in window presents and its intent, in place of
/// `WindowActivation.show`, so a test neither orders a window in nor
/// activates the test process.
final class FakePanelPresenter {
    private(set) var presented: [(window: NSWindow, intent: WindowActivation.Intent)] = []

    func present(_ window: NSWindow, _ intent: WindowActivation.Intent) {
        presented.append((window, intent))
    }
}
