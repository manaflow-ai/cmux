import AppKit
import CmuxBrowser
import SwiftUI

/// Shows a cmux extension dialog (a Chromium install/permission prompt or an
/// automation consent) on the browser's window and returns the answer.
///
/// Design spec §0.9 (modal): on a window without Chromium pages it is a real
/// window sheet. A Chromium page draws in its own child window above the
/// parent and stays above a sheet, so on such a window the dialog
/// is a window-level child panel placed like a sheet (top edge under the
/// titlebar, centered, with a shadow), above an invisible input-blocking
/// panel over the window, both ordered above every page window. Either way it blocks only that window, never activates the
/// app by itself, Escape and Return decline, and a window that closes or a
/// cancelled caller (deadline, socket timeout) declines it.
@MainActor
struct BrowserExtensionDialogPresenter {
    /// Presents `content` on `window` and waits for the answer.
    ///
    /// - Parameters:
    ///   - content: The dialog content.
    ///   - icon: The extension icon (PNG), when known.
    ///   - window: The browser's window.
    ///   - overChromiumPage: True when a Chromium page shows in `window` (its
    ///     page window sits above the parent, so a sheet would be covered).
    /// - Returns: True when the person accepted.
    func present(_ content: BrowserExtensionPromptContent, icon: Data?, in window: NSWindow,
                 overChromiumPage: Bool) async -> Bool {
        let dialog = PromptDialogWindow(overPageWindows: overChromiumPage || Self.hasChromiumPageWindow(window))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { dialog.answer(false) }
                }
                // Debug-build automation lists and answers it (`debug.browser.extension_prompts`).
                let listed = BrowserExtensionOpenDialogs.app.open(content) { dialog.answer($0) }
                dialog.onAnswer = { accepted in
                    BrowserExtensionOpenDialogs.app.close(listed)
                    NotificationCenter.default.removeObserver(closeObserver)
                    dialog.dismiss(from: window)
                    continuation.resume(returning: accepted)
                }
                let view = BrowserExtensionPromptSheetView(
                    content: content,
                    icon: icon.flatMap(NSImage.init(data:)),
                    onAnswer: { dialog.answer($0) }
                )
                let host = NSHostingController(rootView: view)
                dialog.contentViewController = host
                dialog.setContentSize(host.view.fittingSize)
                dialog.identifier = NSUserInterfaceItemIdentifier("browser.extension.prompt")
                // VoiceOver names the window and announces the question (spec §0.7a).
                dialog.title = content.title
                dialog.show(on: window)
                NSAccessibility.post(
                    element: dialog,
                    notification: .announcementRequested,
                    userInfo: [.announcement: content.title, .priority: NSAccessibilityPriorityLevel.high.rawValue]
                )
            }
        } onCancel: {
            Task { @MainActor in dialog.answer(false) }
        }
    }

    /// True when a Chromium page window is attached to `window`.
    static func hasChromiumPageWindow(_ window: NSWindow) -> Bool {
        (window.childWindows ?? []).contains { $0.isVisible && $0.isChromiumPageWindow }
    }

    /// The dialog window: a sheet, or a sheet-like child panel over page windows. Answers once.
    @MainActor
    private final class PromptDialogWindow: NSPanel {
        var onAnswer: ((Bool) -> Void)?
        private let overPageWindows: Bool
        private var inputBlocker: NSPanel?

        init(overPageWindows: Bool) {
            self.overPageWindows = overPageWindows
            let style: NSWindow.StyleMask = overPageWindows
                ? [.titled, .fullSizeContentView]
                : [.titled, .docModalWindow]
            super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                       styleMask: style, backing: .buffered, defer: true)
            isReleasedWhenClosed = false
            if overPageWindows {
                titleVisibility = .hidden
                titlebarAppearsTransparent = true
                standardWindowButton(.closeButton)?.isHidden = true
                standardWindowButton(.miniaturizeButton)?.isHidden = true
                standardWindowButton(.zoomButton)?.isHidden = true
                isMovable = false
                hidesOnDeactivate = false
            }
        }

        override var canBecomeKey: Bool { true }

        func show(on window: NSWindow) {
            guard overPageWindows else {
                window.beginSheet(self)
                return
            }
            // Keep the window modal like a sheet does, without dimming it (a
            // sheet does not dim its parent): an invisible panel over the
            // whole window takes its clicks while the dialog is up.
            let blocker = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            blocker.isOpaque = false
            blocker.hasShadow = false
            // The lowest alpha the window server still hit-tests; it draws nothing visible.
            blocker.backgroundColor = NSColor.black.withAlphaComponent(Self.inputBlockerAlpha)
            blocker.isReleasedWhenClosed = false
            window.addChildWindow(blocker, ordered: .above)
            inputBlocker = blocker
            // A sheet's placement: top edge at the bottom of the titlebar, centered.
            let titlebarHeight = window.frame.height - window.contentLayoutRect.height
            let origin = NSPoint(
                x: (window.frame.midX - frame.width / 2).rounded(),
                y: (window.frame.maxY - titlebarHeight - frame.height).rounded()
            )
            hasShadow = true
            setFrameOrigin(origin)
            window.addChildWindow(self, ordered: .above)
            makeKeyAndOrderFront(nil)
        }

        func dismiss(from window: NSWindow) {
            if let parent = sheetParent {
                parent.endSheet(self)
                return
            }
            window.removeChildWindow(self)
            orderOut(nil)
            if let inputBlocker {
                window.removeChildWindow(inputBlocker)
                inputBlocker.orderOut(nil)
            }
            inputBlocker = nil
        }

        func answer(_ accepted: Bool) {
            guard let onAnswer else { return }
            self.onAnswer = nil
            onAnswer(accepted)
        }

        override func cancelOperation(_ sender: Any?) { answer(false) }

        /// Invisible, but the window server still delivers clicks to it.
        private static let inputBlockerAlpha: CGFloat = 0.01
    }
}
