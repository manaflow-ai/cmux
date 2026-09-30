import AppKit

/// Extension install and permission prompts (fork API 12). Chromium's own
/// dialog would be a Views window of the hidden Chromium window; cmux shows
/// a native sheet on the asking tab's window instead and replies once.
extension CEFRuntime {
    func extensionPromptArrived(promptID: Int32, browser: Int32, json: String) {
        if promptID == 0 {
            if let notice = ExtensionInstalledNotice(json: json) { extensionInstalled(notice, browser: browser) }
            return
        }
        guard let prompt = ExtensionInstallPrompt(id: promptID, browser: browser, json: json),
              let window = promptWindow(for: browser) else {
            logger.error("Extension prompt \(promptID) has no window; aborted")
            _ = shim?.installPromptReply(promptID, ExtensionInstallPrompt.Answer.abort.rawValue)
            return
        }
        logger.notice("Extension prompt \(promptID) \(prompt.kind.rawValue, privacy: .public) for \(prompt.extensionID, privacy: .public)")
        let sheet = ExtensionPromptSheet(prompt: prompt)
        extensionPrompts[promptID] = sheet
        sheet.begin(on: window) { [weak self] answer in
            guard let self, self.extensionPrompts.removeValue(forKey: promptID) != nil else { return }
            self.logger.notice("Extension prompt \(promptID) answered \(answer.rawValue)")
            _ = self.shim?.installPromptReply(promptID, answer.rawValue)
        }
    }

    /// Prompts waiting for an answer (`debug.extensions.prompt`).
    public var pendingExtensionPrompts: [ExtensionInstallPrompt] {
        extensionPrompts.values.map(\.prompt).sorted { $0.id < $1.id }
    }

    /// Answers a waiting prompt as its sheet would. False when it is gone.
    @discardableResult
    public func answerExtensionPrompt(_ id: Int32, _ answer: ExtensionInstallPrompt.Answer) -> Bool {
        guard let sheet = extensionPrompts[id] else { return false }
        sheet.end(answer)
        return true
    }

    /// The window of the tab that asked; else the pane window that showed a
    /// Chromium tab last; else any visible cmux window.
    private func promptWindow(for browser: Int32) -> NSWindow? {
        if let window = tabsByBrowser[browser]?.contentView.window { return window }
        if let window = lastShownHost?.visibleTab?.contentView.window { return window }
        return NSApp.windows.first { $0.isVisible && $0.parent == nil && !($0 is NSPanel) && $0.canBecomeMain }
    }

    /// Chrome shows an "added" bubble at its toolbar; cmux shows a notice on
    /// the tab (the store page that installed it) and refreshes the menu.
    private func extensionInstalled(_ notice: ExtensionInstalledNotice, browser: Int32) {
        logger.notice("Extension installed \(notice.extensionID, privacy: .public)")
        let tab = tabsByBrowser[browser] ?? lastShownHost?.visibleTab
        tab?.emit(.notice(Strings.extensionAdded(notice.name)))
    }
}
