import AppKit
import CmuxNextDesign
import Foundation

/// Page file choosers on Chromium tabs. Chromium shows its own panel unless the shim sends choosers to the
/// app (`cmux_shim_set_file_dialogs`); the app asks for that only while an agent's file offer stands on some
/// tab (`BrowserAgentFiles`, `cmux browser <tab> upload`), so a person's choosers keep Chromium's panel and
/// its accept filters. A chooser that reaches the app goes to its tab's offer first; one from a tab with no
/// offer (another tab while an agent's offer stood) asks the person with the App's panel. A cmux page
/// that records the person's pick (`CEFTab.pageFilesChosen`, the agent chat) sends its own choosers to
/// the app, and only its own (`cmux_shim_browser_set_file_dialogs`).
extension CEFRuntime {
    /// Shim modes (`CEFShimEvent.fileDialog`).
    private enum FileDialogMode: Int32 {
        case open = 0, openMultiple = 1, folder = 2, save = 3
    }

    /// `tab`'s offer started or ended: choosers go to the app while any offer stands.
    func agentFileOfferChanged(_ tab: CEFTab, armed: Bool) {
        let wasOn = choosersGoToApp
        if armed { agentFileOffers.insert(ObjectIdentifier(tab)) } else { agentFileOffers.remove(ObjectIdentifier(tab)) }
        let isOn = choosersGoToApp
        if isOn != wasOn { shim?.setFileDialogs(isOn ? 1 : 0); fileDialogTrace.routedToApp = isOn }
    }

    /// Every chooser goes to the app: while an agent's offer stands, and always with in-tree pages (fork API 36),
    /// where the fork cancels a chooser no CEF handler takes (Chromium's panel would anchor to the page's headless
    /// window; live step ff9c0eb4: in tree `<input type=file>` opened nothing). The person then picks in the App's
    /// panel, without the page's accept filters.
    var choosersGoToApp: Bool { !agentFileOffers.isEmpty || InTreePages.shared.isActive }

    /// Sends `tab`'s own choosers to the app while it records the person's pick, else gives them back.
    func applyFileDialogRoute(_ tab: CEFTab) {
        guard let browser = tab.browserID else { return }
        shim?.browserSetFileDialogs(browser, tab.pageFilesChosen != nil ? 1 : 0)
    }

    /// Answers chooser `dialogID` (shim `mode`) from `tab`: its agent offer, else the person's panel.
    func answerFileDialog(_ dialogID: Int32, mode raw: Int32, defaultPath: String, tab: CEFTab?) {
        let mode = FileDialogMode(rawValue: raw) ?? .open
        fileDialogTrace.received += 1
        if let tab, let offered = tab.agentFiles.answer(multiple: mode == .openMultiple, folder: mode == .folder, save: mode == .save) {
            fileDialogTrace.last = "agent_offer"
            return answerFileDialog(dialogID, multiple: mode == .openMultiple, offered)
        }
        let window = tab?.contentView.window
        if mode == .save { fileDialogTrace.last = "save_panel"; return askWhereToSave(dialogID, defaultPath: defaultPath, window: window) }
        guard let fileInput else { fileDialogTrace.last = "no_file_input"; return answerFileDialog(dialogID, multiple: false, []) }
        fileDialogTrace.last = window == nil ? "open_panel_no_window" : "open_panel_sheet"
        fileDialogTrace.sheetBegins(on: window, paneWindow: tab?.host.hostView.window)
        fileInput.answerFileInput(allowsMultipleSelection: mode == .openMultiple, allowsDirectories: mode == .folder,
                                  window: window) { [weak self, weak tab] urls in
            // The person's pick, before the page gets it (a page that records it, `pageFilesChosen`).
            if let urls, !urls.isEmpty { tab?.pageFilesChosen?(urls) }
            self?.fileDialogTrace.answered = urls.map { "\($0.count) file(s)" } ?? "cancel"
            self?.answerFileDialog(dialogID, multiple: mode == .openMultiple, urls ?? [])
        }
    }

    /// The shim's answer: absolute paths, one per line; none cancels the chooser.
    private func answerFileDialog(_ dialogID: Int32, multiple: Bool, _ urls: [URL]) {
        let paths = urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        _ = paths.withCString { shim?.fileDialogAnswer(dialogID, multiple ? 1 : 0, $0) }
    }

    /// A save chooser (`showSaveFilePicker`) from a tab with no offer: the person picks where.
    private func askWhereToSave(_ dialogID: Int32, defaultPath: String, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if !defaultPath.isEmpty {
            let suggested = URL(fileURLWithPath: defaultPath)
            if defaultPath.hasPrefix("/") { panel.directoryURL = suggested.deletingLastPathComponent() }
            panel.nameFieldStringValue = suggested.lastPathComponent
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            let chosen = response == .OK ? panel?.url : nil
            self?.answerFileDialog(dialogID, multiple: false, chosen.map { [$0] } ?? [])
        }
        // A popup can close under its sheet: the sheet ends with it, so the chooser is still answered.
        if let window { panel.beginSheet(endingWith: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// Page file choosers that reached the app (`debug.cef` `file_dialogs`): whether choosers are routed to the app, how
/// many arrived, the path the last took and how it was answered, and the window the last one's sheet began on then and
/// now. Diagnostics only.
struct CEFFileDialogTrace {
    var routedToApp = false
    var received = 0
    var last: String?
    var answered: String?
    /// The window the last chooser's sheet began on, held weakly so a read reports it as it is now.
    private weak var sheetWindow: NSWindow?
    /// That window, the pane's own window and the app's key and main windows as they were when the sheet began.
    private var atBegin: [String: String] = [:]

    /// The last chooser's sheet begins on `window`; `paneWindow` is the window its tab's pane is in.
    mutating func sheetBegins(on window: NSWindow?, paneWindow: NSWindow?) {
        sheetWindow = window
        atBegin = ["sheet_window": Self.describe(window), "pane_window": Self.describe(paneWindow),
                   "sheet_window_is_pane_window": window != nil && window === paneWindow ? "yes" : "no",
                   "key_window_at_begin": Self.describe(NSApp.keyWindow),
                   "main_window_at_begin": Self.describe(NSApp.mainWindow),
                   "app_active_at_begin": NSApp.isActive ? "yes" : "no"]
    }

    var reportFields: [String: String] {
        var fields = ["routed_to_app": routedToApp ? "yes" : "no", "received": String(received), "last": last ?? "none",
                      "answered": answered ?? "none"]
        guard !atBegin.isEmpty else { return fields }
        fields.merge(atBegin) { $1 }
        // Now: whether the sheet attached to its window, and every panel of the app (an open panel is drawn by
        // AppKit's panel service; this is the app's own window for it).
        fields["sheet_window_now"] = Self.describe(sheetWindow)
        fields["attached_sheet_now"] = Self.describe(sheetWindow?.attachedSheet)
        fields["panels_now"] = NSApp.windows.compactMap { $0 as? NSSavePanel }.map(Self.describe).joined(separator: "; ")
        fields["visible_windows_now"] = NSApp.windows.filter(\.isVisible).map(Self.describe).joined(separator: "; ")
        return fields
    }

    /// One window for the trace: number, class, visibility, key and main, frame, sheet parent.
    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let frame = window.frame
        let parent = window.sheetParent.map { String($0.windowNumber) } ?? "none"
        let parts: [String] = [
            "#\(window.windowNumber)", String(describing: type(of: window)), "visible=\(window.isVisible)",
            "onscreen=\(window.occlusionState.contains(.visible))", "key=\(window.isKeyWindow)", "main=\(window.isMainWindow)",
            "frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))", "sheet_parent=\(parent)",
        ]
        return parts.joined(separator: " ")
    }
}
