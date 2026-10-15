import AppKit
import CmuxBrowser
import SwiftUI

/// Shows a cmux extension sheet (a Chromium install/permission prompt or an
/// automation consent) on the browser's window and returns the answer.
///
/// A window sheet, not an alert (design spec §3a): it blocks only that
/// window, never activates the app by itself, Escape and Return decline, and
/// a cancelled caller (socket timeout) dismisses it as declined.
@MainActor
struct BrowserExtensionDialogPresenter {
    /// Presents `content` on `window` and waits for the answer.
    ///
    /// - Parameters:
    ///   - content: The sheet content.
    ///   - icon: The extension icon (PNG), when known.
    ///   - window: The browser's window.
    ///   - overlays: The page overlay hosts of the Chromium pages in `window`.
    ///     A Chromium page draws in a child window above the sheet, so the
    ///     sheet registers as an occluding overlay (a hole in the page) while it is up.
    /// - Returns: True when the person accepted.
    func present(_ content: BrowserExtensionPromptContent, icon: Data?, in window: NSWindow,
                 overlays: [BrowserPageOverlayCoordinator] = []) async -> Bool {
        let sheet = PromptSheetWindow()
        let occlusionAnchor = NSView(frame: .zero)
        let occlusionID = "browser.extension.sheet.\(ObjectIdentifier(sheet).hashValue)"
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                // A sheet whose window closes is declined, so Chromium or the caller never waits forever.
                let closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { sheet.answer(false) }
                }
                sheet.onAnswer = { accepted in
                    NotificationCenter.default.removeObserver(closeObserver)
                    for coordinator in overlays { coordinator.unregisterOccluding(id: occlusionID) }
                    occlusionAnchor.removeFromSuperview()
                    if let parent = sheet.sheetParent { parent.endSheet(sheet) }
                    continuation.resume(returning: accepted)
                }
                let view = BrowserExtensionPromptSheetView(
                    content: content,
                    icon: icon.flatMap(NSImage.init(data:)),
                    onAnswer: { sheet.answer($0) }
                )
                let host = NSHostingController(rootView: view)
                sheet.contentViewController = host
                sheet.setContentSize(host.view.fittingSize)
                sheet.identifier = NSUserInterfaceItemIdentifier("browser.extension.prompt")
                window.beginSheet(sheet)
                if !overlays.isEmpty, let root = window.contentView {
                    // An invisible stand-in for the sheet in the browser's window, where the overlay host measures.
                    occlusionAnchor.frame = root.convert(window.convertFromScreen(sheet.frame), from: nil)
                    root.addSubview(occlusionAnchor)
                    for coordinator in overlays { coordinator.registerOccluding(occlusionAnchor, id: occlusionID) }
                }
            }
        } onCancel: {
            Task { @MainActor in sheet.answer(false) }
        }
    }

    /// The sheet window: answers once; Escape declines.
    @MainActor
    private final class PromptSheetWindow: NSPanel {
        var onAnswer: ((Bool) -> Void)?

        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                       styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }

        func answer(_ accepted: Bool) {
            guard let onAnswer else { return }
            self.onAnswer = nil
            onAnswer(accepted)
        }

        override func cancelOperation(_ sender: Any?) { answer(false) }
    }
}
