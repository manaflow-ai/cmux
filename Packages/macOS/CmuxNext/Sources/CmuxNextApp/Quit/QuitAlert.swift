import AppKit
import CmuxNextDesign

/// The quit question as cmux dialogs (R96: no system alerts). "Quit cmux?"
/// keeps the terminals by default (Quit, Return), Cancel (Escape), and
/// "End Sessions…" opens "End all terminals?" (End Sessions, Keep Layout;
/// Cancel; End Everything). "Don't ask again" is a check box. Each dialog
/// blocks the active window, or shows app-wide when no window is open
/// (`WindowOverlayHost.appHost()`). It never activates the app by itself.
@MainActor
final class QuitAlert {
    enum Answer: Equatable {
        case quit(QuitSessionsChoice, remember: Bool)
        case cancel
    }

    static let rememberField = "remember"

    let prompt: QuitPrompt
    private(set) var content: QuitAlertContent
    private let center: CmuxDialogCenter
    private var dialogID: Int?
    private var remember = false
    private weak var parent: NSWindow?
    private(set) var isAttached = false
    private var completion: ((Answer) -> Void)?

    init(prompt: QuitPrompt, center: CmuxDialogCenter = .shared, completion: @escaping (Answer) -> Void) {
        self.prompt = prompt
        self.center = center
        self.completion = completion
        content = .main(prompt)
    }

    var lines: [String] { [content.title] + content.lines }
    /// The buttons of the dialog showing now, left to right.
    var buttons: [CmuxDialogButton] { Self.spec(content, remember: remember).buttons }

    var remembers: Bool {
        get {
            guard let dialogID, let value = center.record(dialogID)?.values[Self.rememberField]?.bool else { return remember }
            return value
        }
        set {
            remember = newValue
            if let dialogID { center.setValue(.bool(newValue), for: Self.rememberField, in: dialogID) }
        }
    }

    static func spec(_ content: QuitAlertContent, remember: Bool) -> CmuxDialogSpec {
        let buttons = content.buttons.enumerated().map { index, id in
            CmuxDialogButton(id: id.rawValue, title: QuitAlertContent.title(of: id), role: role(of: id, first: index == 0))
        }
        // Escape order: Cancel is drawn left of the default (the cmux dialog layout).
        let ordered = buttons.filter { $0.role == .cancel } + buttons.filter { $0.role != .cancel }
        let fields: [CmuxDialogField] = content.showsSuppression
            ? [.check(id: rememberField, title: QuitStrings.dontAskAgain, on: remember)] : []
        return CmuxDialogSpec(title: content.title, lines: content.lines, fields: fields, buttons: ordered,
                              identifier: "cmux.dialog.quit")
    }

    /// The first button is the default (Return), Cancel answers Escape, End
    /// Everything is destructive.
    private static func role(of id: QuitAlertContent.Button, first: Bool) -> CmuxDialogButton.Role {
        if id == .cancel { return .cancel }
        if id == .endEverything { return .destructive }
        return first ? .default : .normal
    }

    /// Shows the dialog on `window` (visible, not minimized), else app-wide.
    func present(in window: NSWindow?) {
        guard completion != nil else { return }
        let attach = window.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        parent = attach
        isAttached = attach != nil
        let scope: CmuxDialogScope = attach.map { .window($0) } ?? .app
        dialogID = center.present(Self.spec(content, remember: remember), in: scope) { [weak self] answer in
            self?.answered(answer)
        }
    }

    /// SIGTERM while the alert is open: Quit, keep sessions.
    func answerKeepingSessions() {
        finish(.quit(.keep, remember: false))
    }

    /// Clicks the button `id` ("quit", "cancel", "end", "end-keep-layout",
    /// "end-everything"). False when the dialog shown has no such button.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let dialogID else { return false }
        return center.press(dialogID, button: id)
    }

    private func answered(_ answer: CmuxDialogAnswer) {
        dialogID = nil
        let remembered = answer.values[Self.rememberField]?.bool ?? remember
        switch QuitAlertContent.Button(rawValue: answer.button) {
        case .quit: finish(.quit(prompt.defaultChoice, remember: content.showsSuppression && remembered))
        case .endKeepLayout: finish(.quit(.endKeepLayout, remember: remember))
        case .endEverything: finish(.quit(.endEverything, remember: remember))
        case .endSessions:
            // "End all terminals?" replaces "Quit cmux?" in the same place,
            // carrying "Don't ask again".
            remember = remembered
            content = .endConfirmation
            present(in: parent)
        case .cancel, nil: finish(.cancel)
        }
    }

    /// Ends the dialog and reports `answer` once.
    private func finish(_ answer: Answer) {
        guard let completion else { return }
        self.completion = nil
        if let dialogID {
            self.dialogID = nil
            center.dismiss(dialogID)
        }
        completion(answer)
    }
}
