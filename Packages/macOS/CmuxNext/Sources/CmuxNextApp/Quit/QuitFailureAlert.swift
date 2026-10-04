import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// The text of "Some sessions did not end": one line per failed step of
/// Quit's end choice, then what Quit Anyway leaves running.
enum QuitFailureContent {
    static func lines(_ failures: [EndSessionsFailure]) -> [String] {
        failures.map(line) + [QuitStrings.failedKeepRunning]
    }

    static func line(_ failure: EndSessionsFailure) -> String {
        switch failure.step {
        case .listWorkspaces: QuitStrings.failedListWorkspaces(failure.message)
        case .closeWorkspace(let name): QuitStrings.failedCloseWorkspace(name, failure.message)
        case .shutdownDaemon: QuitStrings.failedShutdown(failure.message)
        case .unsupported: QuitStrings.failedUnsupported(failure.message)
        }
    }
}

/// "Some sessions did not end" after Quit's end choice: Retry (default,
/// Return) runs the end again, Quit Anyway (Escape) quits with what did not
/// end still running. Shown like `QuitAlert` (a sheet on the window, else a
/// floating panel), until the CmuxDialog conversion (R96) replaces both.
@MainActor
final class QuitFailureAlert {
    static let retryID = "retry"
    static let quitAnywayID = "quit-anyway"

    let lines: [String]
    private let alert = NSAlert()
    private(set) var buttons: [(id: String, button: NSButton)] = []
    private var completion: ((QuitFailureAnswer) -> Void)?

    init(failures: [EndSessionsFailure], completion: @escaping (QuitFailureAnswer) -> Void) {
        self.completion = completion
        let lines = QuitFailureContent.lines(failures)
        self.lines = [QuitStrings.failedTitle] + lines
        alert.alertStyle = .warning
        alert.messageText = QuitStrings.failedTitle
        alert.informativeText = lines.joined(separator: "\n")
        for (id, title) in [(Self.retryID, QuitStrings.retry), (Self.quitAnywayID, QuitStrings.quitAnyway)] {
            let button = alert.addButton(withTitle: title)
            button.target = self
            button.action = #selector(pressed(_:))
            button.identifier = NSUserInterfaceItemIdentifier(id)
            if id == Self.quitAnywayID { button.keyEquivalent = "\u{1b}" }
            buttons.append((id, button))
        }
        alert.layout()
    }

    var isAttachedSheet: Bool { alert.window.sheetParent != nil }

    func present(in window: NSWindow?) {
        let panel = alert.window
        if let window, window.isVisible, !window.isMiniaturized {
            window.themeScope.adopt(panel)
            window.beginSheet(panel) { [weak self] response in
                // Ended by someone else (SheetDismissal): quit with what is left.
                if response == .cancel { self?.finish(.quitAnyway) }
            }
            return
        }
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

    /// Clicks `retry` or `quit-anyway`. False for any other id.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let button = buttons.first(where: { $0.id == id })?.button else { return false }
        button.performClick(nil)
        return true
    }

    /// SIGTERM while the alert is open: quit with what is left.
    func answerQuitAnyway() { finish(.quitAnyway) }

    @objc private func pressed(_ sender: NSButton) {
        finish(sender.identifier?.rawValue == Self.retryID ? .retry : .quitAnyway)
    }

    private func finish(_ answer: QuitFailureAnswer) {
        guard let completion else { return }
        self.completion = nil
        let panel = alert.window
        if let sheetParent = panel.sheetParent { sheetParent.endSheet(panel, returnCode: .OK) } else { panel.orderOut(nil) }
        completion(answer)
    }
}
