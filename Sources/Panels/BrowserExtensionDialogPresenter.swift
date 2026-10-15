import AppKit
import CmuxBrowser
import SwiftUI

/// Shows a cmux extension dialog (a Chromium install/permission prompt or an
/// automation consent) on the browser's window and returns the answer.
///
/// Design spec §0.9 (modal): on a window without Chromium pages it is a real
/// window sheet. A Chromium page draws in its own child window above the
/// parent, which a sheet cannot dim or cover, so on such a window the dialog
/// is a window-level child panel placed like a sheet (top center), above a
/// dimming child panel that covers the whole window, both ordered above every
/// page window. Either way it blocks only that window, never activates the
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
                dialog.onAnswer = { accepted in
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
                dialog.show(on: window)
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
        private var dimming: NSPanel?

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
            // Dim the whole window evenly (page windows included) and swallow its clicks.
            let dim = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            dim.isOpaque = false
            dim.hasShadow = false
            dim.backgroundColor = NSColor.black.withAlphaComponent(Self.dimmingAlpha)
            dim.isReleasedWhenClosed = false
            window.addChildWindow(dim, ordered: .above)
            dimming = dim
            // Sheet position: top center of the window's content.
            let content = window.contentLayoutRect
            let origin = NSPoint(
                x: window.frame.minX + content.midX - frame.width / 2,
                y: window.frame.minY + content.maxY - frame.height - Self.topInset
            )
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
            if let dimming {
                window.removeChildWindow(dimming)
                dimming.orderOut(nil)
            }
            dimming = nil
        }

        func answer(_ accepted: Bool) {
            guard let onAnswer else { return }
            self.onAnswer = nil
            onAnswer(accepted)
        }

        override func cancelOperation(_ sender: Any?) { answer(false) }

        /// Matches the dimming AppKit draws behind a sheet.
        private static let dimmingAlpha: CGFloat = 0.2
        /// Gap between the window's top edge and the dialog, like a sheet's drop.
        private static let topInset: CGFloat = 8
    }
}
