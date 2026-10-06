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
        case .endAgents: QuitStrings.failedEndAgents(failure.message)
        }
    }
}

/// "Some sessions did not end" after Quit's end choice, as a cmux dialog
/// (R96): Retry (default, Return) runs the end again, Quit Anyway (Escape)
/// quits with what did not end still running. It blocks the window like
/// `QuitAlert`, else shows app-wide; a closed window or SIGTERM answers
/// Quit Anyway.
@MainActor
final class QuitFailureAlert {
    static let retryID = "retry"
    static let quitAnywayID = "quit-anyway"

    let lines: [String]
    let buttons: [(id: String, title: String)]
    private let body: [String]
    private let center: CmuxDialogCenter
    private var dialogID: Int?
    private(set) var isAttachedSheet = false
    private var completion: ((QuitFailureAnswer) -> Void)?

    init(failures: [EndSessionsFailure], center: CmuxDialogCenter = .shared, completion: @escaping (QuitFailureAnswer) -> Void) {
        self.completion = completion
        self.center = center
        body = QuitFailureContent.lines(failures)
        lines = [QuitStrings.failedTitle] + body
        buttons = [(Self.quitAnywayID, QuitStrings.quitAnyway), (Self.retryID, QuitStrings.retry)]
    }

    var spec: CmuxDialogSpec {
        CmuxDialogSpec(title: QuitStrings.failedTitle, lines: body,
                       buttons: [CmuxDialogButton(id: Self.quitAnywayID, title: QuitStrings.quitAnyway, role: .cancel),
                                 CmuxDialogButton(id: Self.retryID, title: QuitStrings.retry, role: .default)],
                       identifier: "cmux.dialog.quitFailure")
    }

    func present(in window: NSWindow?) {
        guard completion != nil else { return }
        let attach = window.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        isAttachedSheet = attach != nil
        dialogID = center.present(spec, in: attach.map { .window($0) } ?? .app) { [weak self] answer in
            self?.dialogID = nil
            self?.finish(answer.button == Self.retryID ? .retry : .quitAnyway)
        }
    }

    /// Clicks `retry` or `quit-anyway`. False for any other id.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let dialogID, buttons.contains(where: { $0.id == id }) else { return false }
        return center.press(dialogID, button: id)
    }

    /// SIGTERM while the dialog is open: quit with what is left.
    func answerQuitAnyway() { finish(.quitAnyway) }

    private func finish(_ answer: QuitFailureAnswer) {
        guard let completion else { return }
        self.completion = nil
        if let dialogID {
            self.dialogID = nil
            center.dismiss(dialogID)
        }
        completion(answer)
    }
}
