import AppKit
import CmuxNextDesign

/// The quit question as cmux dialogs (R96, R138: no system alerts). "Quit
/// cmux?" keeps the terminals by default (Keep Sessions Running, Return),
/// Cancel (Escape), and "Quit Everything…" opens "End all terminals?"
/// (Quit Everything, Cancel, End Everything; no Return default). "Don't ask
/// again" is a check box. Each dialog blocks the window `QuitCoordinator`
/// picks, or shows app-wide when no window is open (the app host, which
/// activates the app).
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
        let buttons = content.buttons.map { id in
            CmuxDialogButton(id: id.rawValue, title: QuitAlertContent.title(of: id), role: role(of: id))
        }
        // Drawn left to right: the other choices, Cancel, then the primary one.
        let primary = buttons.prefix(1)
        let rest = buttons.dropFirst()
        let ordered = rest.filter { $0.role != .cancel } + rest.filter { $0.role == .cancel } + primary
        let fields: [CmuxDialogField] = content.showsSuppression
            ? [.check(id: rememberField, title: QuitStrings.dontAskAgain, on: remember)] : []
        return CmuxDialogSpec(title: content.title, lines: content.lines, fields: fields, buttons: ordered,
                              identifier: "cmux.dialog.quit")
    }

    /// Keep (or Quit) answers Return, Cancel answers Escape, every end choice
    /// is destructive and has no key.
    private static func role(of id: QuitAlertContent.Button) -> CmuxDialogButton.Role {
        switch id {
        case .keep, .quit: .default
        case .cancel: .cancel
        case .quitEverything, .confirmQuitEverything, .endEverything: .destructive
        }
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

    /// Clicks the button `id` ("keep", "quit", "cancel", "quit-everything",
    /// "confirm-quit-everything", "end-everything"; the old "end" and
    /// "end-keep-layout" still work). False when the dialog shown has no
    /// such button.
    @discardableResult
    func press(_ id: String) -> Bool {
        guard let dialogID else { return false }
        let ids = buttons.map(\.id)
        let resolved = switch id {
        case "quit" where !ids.contains("quit"): "keep"
        case "end": "quit-everything"
        case "end-keep-layout": "confirm-quit-everything"
        default: id
        }
        return center.press(dialogID, button: resolved)
    }

    /// A second Cmd-Q while the dialog shows: the default on the first step
    /// (keep), nothing on the confirmation.
    func answerDefault() {
        guard content.isFirstStep, let primary = content.buttons.first else { return }
        press(primary.rawValue)
    }

    private func answered(_ answer: CmuxDialogAnswer) {
        dialogID = nil
        let remembered = answer.values[Self.rememberField]?.bool ?? remember
        switch QuitAlertContent.Button(rawValue: answer.button) {
        case .keep: finish(.quit(.keep, remember: content.showsSuppression && remembered))
        case .quit: finish(.quit(prompt.defaultChoice, remember: content.showsSuppression && remembered))
        case .confirmQuitEverything: finish(.quit(.endKeepLayout, remember: remember))
        case .endEverything: finish(.quit(.endEverything, remember: remember))
        case .quitEverything:
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
