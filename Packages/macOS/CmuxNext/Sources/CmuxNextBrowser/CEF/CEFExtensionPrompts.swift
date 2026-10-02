import AppKit

/// Extension install and permission prompts (fork API 12). Chromium's own
/// dialog would be a Views window of the hidden Chromium window; cmux shows
/// a native sheet on the asking tab's window instead and replies once.
/// Owns the sheets on screen, by Chromium prompt id.
@MainActor
final class CEFExtensionPrompts {
    unowned let runtime: CEFRuntime
    private var sheets: [Int32: ExtensionPromptSheet] = [:]

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    func arrived(promptID: Int32, browser: Int32, json: String) {
        if promptID == 0 {
            if let notice = ExtensionInstalledNotice(json: json) { installed(notice, browser: browser) }
            return
        }
        guard let prompt = ExtensionInstallPrompt(id: promptID, browser: browser, json: json),
              let window = window(for: browser) else {
            runtime.logger.error("Extension prompt \(promptID) has no window; aborted")
            _ = runtime.shim?.installPromptReply(promptID, ExtensionInstallPrompt.Answer.abort.rawValue)
            return
        }
        runtime.logger.notice("Extension prompt \(promptID) \(prompt.kind.rawValue, privacy: .public) for \(prompt.extensionID, privacy: .public)")
        let sheet = ExtensionPromptSheet(prompt: prompt)
        sheets[promptID] = sheet
        sheet.begin(on: window) { [weak self] answer in
            guard let self, self.sheets.removeValue(forKey: promptID) != nil else { return }
            self.runtime.logger.notice("Extension prompt \(promptID) answered \(answer.rawValue)")
            _ = self.runtime.shim?.installPromptReply(promptID, answer.rawValue)
        }
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

    /// The window of the tab that asked; else the pane window that showed a
    /// Chromium tab last; else any visible cmux window.
    private func window(for browser: Int32) -> NSWindow? {
        if let window = runtime.tabsByBrowser[browser]?.contentView.window { return window }
        if let window = runtime.lastShownHost?.visibleTab?.contentView.window { return window }
        return NSApp.windows.first { $0.isVisible && $0.parent == nil && !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// Shows a notice on the tab (the store page that installed the
    /// extension) and refreshes the menu.
    private func installed(_ notice: ExtensionInstalledNotice, browser: Int32) {
        runtime.logger.notice("Extension installed \(notice.extensionID, privacy: .public)")
        let tab = runtime.tabsByBrowser[browser] ?? runtime.lastShownHost?.visibleTab
        tab?.emit(.notice(Strings.extensionAdded(notice.name)))
    }
}
