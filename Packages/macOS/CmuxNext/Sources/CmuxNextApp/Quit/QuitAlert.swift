import AppKit
import CmuxNextDesign

/// The quit question as plain NSAlerts (system font, spacing, app icon and
/// button colors; nothing custom). "Quit cmux?" keeps the terminals by
/// default (Quit, Return), Cancel (Escape), and "End Sessions…" opens "End
/// all terminals?" (End Sessions, Keep Layout; Cancel; End Everything).
/// "Don't ask again" is the alert's suppression checkbox. Each alert is a
/// sheet on `window`, or a floating panel when no window is open. Buttons
/// report through their own target, so no modal session or nested run loop
/// runs.
@MainActor
final class QuitAlert {
    enum Answer: Equatable {
        case quit(QuitSessionsChoice, remember: Bool)
        case cancel
    }

    let prompt: QuitPrompt
    private(set) var content: QuitAlertContent
    private var alert: NSAlert
    private(set) var buttons: [(id: String, button: NSButton)] = []
    private var remember = false
    private weak var parent: NSWindow?
    private var completion: ((Answer) -> Void)?

    init(prompt: QuitPrompt, completion: @escaping (Answer) -> Void) {
        self.prompt = prompt
        self.completion = completion
        content = .main(prompt)
        alert = NSAlert()
        build()
    }

    var lines: [String] { [content.title] + content.lines }
    var remembers: Bool {
        get { alert.suppressionButton?.state == .on || remember }
        set {
            remember = newValue
            alert.suppressionButton?.state = newValue ? .on : .off
        }
    }
    /// Attached to a window (else a floating panel).
    var isAttachedSheet: Bool { alert.window.sheetParent != nil }

    private func build() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = content.title
        alert.informativeText = content.message
        buttons = content.buttons.map { id in
            let button = alert.addButton(withTitle: QuitAlertContent.title(of: id))
            button.target = self
            button.action = #selector(pressed(_:))
            button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            if id == .cancel { button.keyEquivalent = "\u{1b}" }
            if id == .endEverything { button.hasDestructiveAction = true }
            return (id.rawValue, button)
        }
        alert.showsSuppressionButton = content.showsSuppression
        alert.suppressionButton?.title = QuitStrings.dontAskAgain
        alert.suppressionButton?.state = remember ? .on : .off
        alert.layout()
        self.alert = alert
    }

    /// Shows the alert on `window` (visible, not minimized), else floating.
    /// Never activates the app in a no-activate launch.
    func present(in window: NSWindow?) {
        let panel = alert.window
        if let window, window.isVisible, !window.isMiniaturized {
            parent = window
            window.themeScope.adopt(panel)
            window.beginSheet(panel) { [weak self] response in
                // Ended by someone else (SheetDismissal): a cancel.
                if response == .cancel { self?.finish(.cancel) }
            }
            return
        }
        parent = nil
        ThemeScope.app.adopt(panel)
        panel.level = .floating
        panel.center()
        if WindowPlacement.noActivate {
            panel.orderFrontRegardless()
        } else {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// SIGTERM while the alert is open: Quit, keep sessions.
    func answerKeepingSessions() {
        // not implemented yet
    }

    /// Clicks the button `id` ("quit", "cancel", "end", "end-keep-layout",
    /// "end-everything"). False when the alert shown has no such button.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let button = buttons.first(where: { $0.id == id })?.button else { return false }
        button.performClick(nil)
        return true
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ QuitAlertContent.Button(rawValue: $0.rawValue) }) else { return }
        switch id {
        case .quit: finish(.quit(prompt.defaultChoice, remember: content.showsSuppression && remembers))
        case .cancel: finish(.cancel)
        case .endKeepLayout: finish(.quit(.endKeepLayout, remember: remember))
        case .endEverything: finish(.quit(.endEverything, remember: remember))
        case .endSessions: showEndConfirmation()
        }
    }

    /// Replaces "Quit cmux?" with "End all terminals?" in the same place,
    /// carrying "Don't ask again".
    private func showEndConfirmation() {
        remember = remembers
        let window = parent
        close()
        content = .endConfirmation
        build()
        present(in: window)
    }

    private func close() {
        let panel = alert.window
        if let sheetParent = panel.sheetParent { sheetParent.endSheet(panel, returnCode: .OK) } else { panel.orderOut(nil) }
    }

    /// Closes the alert and reports `answer` once.
    private func finish(_ answer: Answer) {
        guard let completion else { return }
        self.completion = nil
        close()
        completion(answer)
    }
}
