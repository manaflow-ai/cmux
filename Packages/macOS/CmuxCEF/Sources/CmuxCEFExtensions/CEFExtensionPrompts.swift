public import AppKit
public import CmuxBrowser
public import CmuxCEF
import Foundation

/// Answers Chromium's extension install and permission prompts (fork API 12)
/// with a cmux sheet on the asking tab's window.
///
/// Chromium waits until cmux replies exactly once. Only the person answers:
/// there is no automation path to accept a prompt. A prompt with no window
/// to ask in is aborted (fail closed). Prompt id 0 is the "installed" notice,
/// which needs no reply.
@MainActor
public final class CEFExtensionPrompts {
    /// Shows a sheet and returns the answer: true accept, false decline.
    public typealias Present = @MainActor (BrowserExtensionPromptContent, Data?, NSWindow) async -> Bool

    private let calls: any CEFExtensionCalls
    private let window: @MainActor (Int32) -> NSWindow?
    private let present: Present
    private let installed: @MainActor (BrowserExtensionInstalledNotice, Int32) -> Void
    private var pending: [Int32: BrowserExtensionInstallPrompt] = [:]
    private var observerToken: UUID?

    /// Creates the prompt handler.
    ///
    /// - Parameters:
    ///   - calls: The fork's calls (for the reply).
    ///   - window: The window to ask in for a browser id: the asking tab's, else
    ///     a visible cmux window; nil aborts the prompt.
    ///   - present: Shows the sheet.
    ///   - installed: Shows the "extension added" notice for the installing browser.
    public init(
        calls: any CEFExtensionCalls,
        window: @escaping @MainActor (Int32) -> NSWindow?,
        present: @escaping Present,
        installed: @escaping @MainActor (BrowserExtensionInstalledNotice, Int32) -> Void
    ) {
        self.calls = calls
        self.window = window
        self.present = present
        self.installed = installed
    }

    /// Routes the runtime's install-prompt events to ``arrived(promptID:browser:json:)``.
    public func observe(_ runtime: CEFRuntime) {
        guard observerToken == nil else { return }
        observerToken = runtime.addEventObserver { [weak self] event in
            guard case .installPrompt(let browser, let promptID, let json) = event else { return }
            self?.arrived(promptID: promptID, browser: browser, json: json)
        }
    }

    /// The prompts waiting for the person, oldest first.
    public var waiting: [BrowserExtensionInstallPrompt] {
        pending.values.sorted { $0.id < $1.id }
    }

    /// Handles one prompt event.
    public func arrived(promptID: Int32, browser: Int32, json: String) {
        if promptID == 0 {
            if let notice = BrowserExtensionInstalledNotice(json: json) { installed(notice, browser) }
            return
        }
        guard let prompt = BrowserExtensionInstallPrompt(id: promptID, browser: browser, json: json),
              let window = window(browser) else {
            _ = calls.replyToPrompt(promptID, answer: BrowserExtensionInstallPrompt.Answer.abort.rawValue)
            return
        }
        pending[promptID] = prompt
        let content = BrowserExtensionPromptContent(prompt: prompt)
        Task { @MainActor [weak self, present] in
            let accepted = await present(content, prompt.icon, window)
            self?.finish(promptID, accepted ? .accept : .cancel)
        }
    }

    private func finish(_ promptID: Int32, _ answer: BrowserExtensionInstallPrompt.Answer) {
        guard pending.removeValue(forKey: promptID) != nil else { return }
        _ = calls.replyToPrompt(promptID, answer: answer.rawValue)
    }
}
