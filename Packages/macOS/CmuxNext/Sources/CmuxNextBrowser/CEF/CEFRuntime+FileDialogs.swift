import AppKit
import CmuxNextDesign
import Foundation

/// Page file choosers on Chromium tabs. Chromium shows its own panel unless the shim sends choosers to the
/// app (`cmux_shim_set_file_dialogs`); the app asks for that only while an agent's file offer stands on some
/// tab (`BrowserAgentFiles`, `cmux browser <tab> upload`), so a person's choosers keep Chromium's panel and
/// its accept filters. A chooser that reaches the app goes to its tab's offer first; one from a tab with no
/// offer (another tab while an agent's offer stood) asks the person with the App's panel. In host mode with
/// cmux's pickers (feature `chromiumHostFileDialogs`, ``ChromiumHostFiles``) every chooser reaches the app;
/// one with no offer for its tab goes to that picker.
extension CEFRuntime {
    /// `tab`'s offer started or ended: choosers go to the app while any offer stands. In host mode with
    /// cmux's pickers they always do (``answerHostFileDialogs(_:)``), so an offer's end keeps them on.
    func agentFileOfferChanged(_ tab: CEFTab, armed: Bool) {
        let wasOn = !agentFileOffers.isEmpty
        if armed { agentFileOffers.insert(ObjectIdentifier(tab)) } else { agentFileOffers.remove(ObjectIdentifier(tab)) }
        let isOn = !agentFileOffers.isEmpty
        if isOn != wasOn, hostStart?.files == nil { shim?.setFileDialogs(isOn ? 1 : 0) }
    }

    /// Answers chooser `dialogID` from `browser`'s tab: its agent offer, else cmux's host picker
    /// (``fileDialogAsked(_:browser:request:)``), else the person's panel.
    func answerFileDialog(_ dialogID: Int32, browser: Int32, request: ChromiumFileDialogRequest) {
        let mode = request.mode
        let tab = tabsByBrowser[browser]
        if let tab, let offered = tab.agentFiles.answer(multiple: mode == .openMultiple, folder: mode == .folder, save: mode == .save) {
            return answerFileDialog(dialogID, multiple: mode == .openMultiple, offered)
        }
        if hostStart?.files != nil { return fileDialogAsked(dialogID, browser: browser, request: request) }
        let window = tab?.contentView.window
        let defaultPath = request.defaultPath
        if mode == .save { return askWhereToSave(dialogID, defaultPath: defaultPath, window: window) }
        guard let fileInput else { return answerFileDialog(dialogID, multiple: false, []) }
        fileInput.answerFileInput(allowsMultipleSelection: mode == .openMultiple, allowsDirectories: mode == .folder,
                                  window: window) { [weak self] urls in
            self?.answerFileDialog(dialogID, multiple: mode == .openMultiple, urls ?? [])
        }
    }

    /// The shim's answer: absolute paths, one per line; none cancels the chooser.
    private func answerFileDialog(_ dialogID: Int32, multiple: Bool, _ urls: [URL]) {
        _ = shim?.fileDialogAnswer(dialogID, multiple ? 1 : 0, ChromiumFileDialogRequest.paths(urls))
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
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}
