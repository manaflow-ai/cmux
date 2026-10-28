import AppKit
import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextDesign

/// Extension install and permission prompts (fork API 12). Chromium's own
/// dialog would be a Views window of the hidden Chromium window; cmux shows
/// a cmux dialog on the asking tab instead and replies once.
/// Owns the sheets on screen, by Chromium prompt id.
@MainActor
final class CEFExtensionPrompts {
    /// The runtime, which owns these as `CEFRuntime.extensionPrompts`.
    private let runtimeReference: OwnerReference<CEFRuntime>
    /// The runtime; nil (reported) only once it is gone.
    private var runtime: CEFRuntime? { runtimeReference.resolve() }
    private var sheets: [Int32: ExtensionPromptSheet] = [:]

    init(runtime: CEFRuntime) {
        runtimeReference = CEFRuntime.childReference(runtime)
    }

    func arrived(promptID: Int32, browser: Int32, json: String) {
        guard let runtime else { return }
        if promptID == 0 {
            if let notice = ExtensionInstalledNotice(json: json) { installed(notice, browser: browser, in: runtime) }
            return
        }
        guard let prompt = ExtensionInstallPrompt(id: promptID, browser: browser, json: json),
              let scope = scope(for: browser, in: runtime) else {
            runtime.logger.error("Extension prompt \(promptID) has no window; aborted")
            _ = runtime.shim?.installPromptReply(promptID, ExtensionInstallPrompt.Answer.abort.rawValue)
            return
        }
        runtime.logger.notice("Extension prompt \(promptID) \(prompt.kind.rawValue, privacy: .public) for \(prompt.extensionID, privacy: .public)")
        let sheet = ExtensionPromptSheet(prompt: prompt)
        sheets[promptID] = sheet
        sheet.begin(in: scope) { [weak self] answer in
            guard let self, self.sheets.removeValue(forKey: promptID) != nil, let runtime = self.runtime else { return }
            runtime.logger.notice("Extension prompt \(promptID) answered \(answer.rawValue)")
            _ = runtime.shim?.installPromptReply(promptID, answer.rawValue)
        }
    }

    /// The Chromium Host ended (`CEFRuntime.hostGone`, task 091): the prompts were its own, so every
    /// sheet closes in this turn and no answer is sent, as a dead pipe's dialogs close in Chrome
    /// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `NotifyError`).
    func hostEnded() {
        let shown = Array(sheets.values)
        sheets.removeAll()
        // Each completion finds its prompt gone from `sheets` and replies nothing.
        for sheet in shown { sheet.end(.abort) }
    }

    /// Prompts waiting for an answer (`debug.extensions.prompt`).
    var pending: [ExtensionInstallPrompt] {
        sheets.values.map(\.prompt).sorted { $0.id < $1.id }
    }

    /// Answers a waiting prompt as its sheet would. False when it is gone.
    @discardableResult
    func answer(_ id: Int32, _ answer: ExtensionInstallPrompt.Answer) -> Bool {
        guard let sheet = sheets[id] else { return false }
        sheet.end(answer)
        return true
    }

    /// The tab that asked (only that tab is blocked); else the pane window
    /// that showed a Chromium tab last; else any visible cmux window.
    private func scope(for browser: Int32, in runtime: CEFRuntime) -> CmuxDialogScope? {
        if let view = runtime.tabsByBrowser[browser]?.contentView, view.window != nil, !view.isHiddenOrHasHiddenAncestor { return .tab(view) }
        if let window = runtime.lastShownHost?.visibleTab?.contentView.window { return .window(window) }
        return NSApp.windows.first { $0.isVisible && $0.parent == nil && !($0 is NSPanel) && $0.canBecomeMain }.map { .window($0) }
    }

    /// Shows a notice on the tab (the store page that installed the
    /// extension) and refreshes the menu.
    private func installed(_ notice: ExtensionInstalledNotice, browser: Int32, in runtime: CEFRuntime) {
        runtime.logger.notice("Extension installed \(notice.extensionID, privacy: .public)")
        let tab = runtime.tabsByBrowser[browser] ?? runtime.lastShownHost?.visibleTab
        tab?.emit(.notice(Strings.extensionAdded(notice.name)))
    }
}
