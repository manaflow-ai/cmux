public import AppKit

/// A page's `<input type="file">` answered with the panel made ahead (``MadeAheadOpenPanel/panel()``): the click
/// pays only the sheet, and a dead panel shows no sheet, so the page gets its cancel at once instead of a handler
/// that may never come.
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
