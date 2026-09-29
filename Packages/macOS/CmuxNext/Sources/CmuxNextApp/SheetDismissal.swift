import AppKit

/// Ends open sheets (result, status, confirmation, rename prompts) as
/// cancelled. Quit calls it first: a window with an attached sheet holds
/// termination until someone answers the sheet.
enum SheetDismissal {
    /// Ends every sheet attached to `windows` (nested sheets first).
    /// Returns how many ended.
    @discardableResult
    static func endAll(in windows: [NSWindow] = NSApp.windows) -> Int {
        var ended = 0
        for window in windows {
            while let sheet = deepestSheet(of: window) {
                (sheet.sheetParent ?? window).endSheet(sheet, returnCode: .cancel)
                ended += 1
            }
        }
        return ended
    }

    private static func deepestSheet(of window: NSWindow) -> NSWindow? {
        var sheet = window.attachedSheet
        while let nested = sheet?.attachedSheet { sheet = nested }
        return sheet
    }
}
