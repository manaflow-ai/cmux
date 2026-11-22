public import AppKit

/// A WebKit page's `<input type="file">` answered through ``MadeAheadOpenPanel/panel()``.
///
/// When a panel was made ahead and is free, the click pays only the sheet. When none is (no warm-up has run, as in
/// a session with only browser tabs, which do not warm it; or after a dead panel), the click makes the panel itself:
/// a synchronous `NSOpenPanel()` on the main thread, 160 to 830 ms on a working host and up to about 40 s when the
/// panel service hangs or is absent. A panel that comes back dead shows no sheet, so the page then gets its cancel
/// after that block instead of waiting forever on a sheet handler that never comes; the block itself stays (no
/// deadline is possible around `NSOpenPanel()`; the fix is cmux's own picker, plans/cmux-next/picker.md).
extension MadeAheadOpenPanel: WebFileInputAnswering {
    public func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                                completion: @escaping @MainActor ([URL]?) -> Void) {
        guard let panel = panel() else {
            completion(nil)
            return
        }
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
