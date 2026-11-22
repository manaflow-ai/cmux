import AppKit
import CmuxNextDesign

/// Ends open sheets and every open cmux dialog (`CmuxDialogCenter`) as
/// cancelled. Quit calls it first: a window with an attached sheet holds
/// termination until someone answers the sheet.
enum SheetDismissal {
    /// Ends every sheet attached to `windows` (nested sheets first).
    /// Returns how many ended.
    @discardableResult
    static func endAll(in windows: [NSWindow] = NSApp.windows) -> Int {
        var ended = CmuxDialogCenter.shared.records.count
        CmuxDialogCenter.shared.dismissAll()
        for window in windows {
            while let sheet = deepestSheet(of: window) {
                (sheet.sheetParent ?? window).endSheet(sheet, returnCode: .cancel)
                ended += 1
            }
        }
        return ended
    }

    /// Ends the topmost sheet on `window` (a nested sheet before its parent)
    /// as cancelled. Returns whether one ended.
    @discardableResult
    static func endTopmost(of window: NSWindow) -> Bool {
        guard let sheet = deepestSheet(of: window) else { return false }
        (sheet.sheetParent ?? window).endSheet(sheet, returnCode: .cancel)
        return true
    }

    private static func deepestSheet(of window: NSWindow) -> NSWindow? {
        var sheet = window.attachedSheet
        while let nested = sheet?.attachedSheet { sheet = nested }
        return sheet
    }
}
