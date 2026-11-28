public import AppKit

extension NSSavePanel {
    /// `beginSheetModal(for:completionHandler:)` that also ends, with cancel, when `window` closes under the sheet.
    ///
    /// AppKit never ends a sheet whose window closes while it shows (a `window.open` popup that closes, by its page or
    /// its close button, while its page's file chooser is up): the handler never runs, so the chooser is never
    /// answered, and the panel, ordered out with that window, looks free (not visible, no sheet parent) while it is
    /// still in that sheet's session. Handed out again (``MadeAheadOpenPanel``) its Cancel ran the old handler, and
    /// the new chooser was never answered (other-Mac run on 6e420b7b: after one such popup every later chooser of the
    /// app failed). Here the sheet ends as its window starts to close: the panel cancels, `completionHandler` runs
    /// with `.cancel`, and the panel is free again. `completionHandler` runs once.
    ///
    /// - Parameter stuck: runs when the window closed and neither the panel's cancel nor `endSheet` ended the sheet
    ///   (the handler then ran with `.cancel` all the same): the panel is still caught in that sheet, so the caller
    ///   must never show it again.
    public func beginSheet(endingWith window: NSWindow,
                           completionHandler: @escaping @MainActor (NSApplication.ModalResponse) -> Void,
                           stuck: @escaping @MainActor () -> Void = {}) {
        let sheet = SheetWithWindow(completionHandler)
        sheet.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                queue: nil) { [weak self, weak window] _ in
            // `close()` posts it on the main thread, before the window and its sheet order out.
            MainActor.assumeIsolated {
                guard !sheet.answered else { return }
                self?.cancel(nil)
                if !sheet.answered, let self, let window { window.endSheet(self, returnCode: .cancel) }
                guard !sheet.answered else { return }
                sheet.answer(.cancel)
                stuck()
            }
        }
        beginSheetModal(for: window) { response in sheet.answer(response) }
    }
}

/// One sheet's handler, run once, and its window's close observer.
@MainActor
private final class SheetWithWindow {
    private var handler: (@MainActor (NSApplication.ModalResponse) -> Void)?
    var observer: (any NSObjectProtocol)?
    var answered: Bool { handler == nil }

    init(_ handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) { self.handler = handler }

    func answer(_ response: NSApplication.ModalResponse) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let handler = handler
        self.handler = nil
        handler?(response)
    }
}
