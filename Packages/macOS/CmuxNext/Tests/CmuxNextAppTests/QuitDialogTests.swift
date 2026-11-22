@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// R96: the quit question is a cmux dialog (no system alert). Return quits
/// and keeps the terminals, Escape cancels, and the end choices sit in the
/// same dialog with "Don't ask again" (#17501: never a second step).
@MainActor
struct QuitDialogTests {
    static let prompt = QuitPrompt(terminals: 3, runningPrograms: 1, busiest: ["vim"], incognitoPrograms: [],
                                   remoteSessions: false, offersSessionChoice: true, defaultChoice: .keep)

    static func open() -> (QuitAlert, CmuxDialogCenter, () -> [QuitAlert.Answer]) {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [QuitAlert.Answer] = []
        let alert = QuitAlert(prompt: prompt, center: center) { answers.append($0) }
        alert.present(in: nil)
        return (alert, center, { answers })
    }

    @Test func returnQuitsAndKeepsTheTerminals() throws {
        let (alert, center, answers) = Self.open()
        defer { withExtendedLifetime(alert) {} }
        let id = try #require(center.records.first?.id)
        #expect(center.records.first?.scope == "app", "no window: app-wide")
        center.key(.return, in: id)
        #expect(answers() == [.quit(.keep, remember: false)])
        #expect(center.records.isEmpty)
    }

    @Test func escapeCancels() throws {
        let (alert, center, answers) = Self.open()
        defer { withExtendedLifetime(alert) {} }
        center.key(.escape, in: try #require(center.records.first?.id))
        #expect(answers() == [.cancel])
    }

    @Test func keepSessionsRunningIsTheDefaultAndTheEndChoicesNeedNoSecondStep() throws {
        let (alert, center, answers) = Self.open()
        let main = try #require(center.records.first)
        #expect(main.spec.buttons.map(\.id) == ["confirm-quit-everything", "cancel", "keep"])
        #expect(main.spec.defaultButton?.id == "keep", "Return never confirms a destructive choice")
        #expect(main.spec.buttons.first?.role == .destructive)
        alert.remembers = true
        #expect(alert.press("confirm-quit-everything"))
        #expect(answers() == [.quit(.endKeepLayout, remember: true)])
        #expect(center.records.isEmpty, "no second dialog")
    }

    @Test func theOldButtonIDsStillWork() {
        let (alert, _, answers) = Self.open()
        #expect(alert.press("end"))
        #expect(answers().isEmpty, "end only opened the old second step")
        #expect(alert.press("end-keep-layout"))
        #expect(answers() == [.quit(.endKeepLayout, remember: false)])
        let (old, _, oldAnswers) = Self.open()
        #expect(old.press("quit-everything"))
        #expect(oldAnswers() == [.quit(.endKeepLayout, remember: false)])
    }

    /// hq-48's fleet quit script drives the dialog only through `debug.quit`
    /// press names: quit, cancel, end, end-everything (and quit-anyway on
    /// the failure dialog, QuitFailureDialogTests). They stay valid.
    @Test func theSocketPressNamesStayValid() {
        let (keep, _, keepAnswers) = Self.open()
        #expect(keep.press("quit"))
        #expect(keepAnswers() == [.quit(.keep, remember: false)])
        let (cancel, _, cancelAnswers) = Self.open()
        #expect(cancel.press("cancel"))
        #expect(cancelAnswers() == [.cancel])
        let (end, _, endAnswers) = Self.open()
        #expect(end.press("end"))
        #expect(end.press("end-everything"))
        #expect(endAnswers() == [.quit(.endEverything, remember: false)])
    }

    /// A second Cmd-Q while the dialog shows confirms the default (keep).
    @Test func aSecondQuitKeeps() {
        let (alert, _, answers) = Self.open()
        alert.answerDefault()
        #expect(answers() == [.quit(.keep, remember: false)])
    }

    /// A quit from the Dock or the app switcher while cmux is inactive brings
    /// cmux forward before it asks; scripted, signal and power-off quits never ask.
    @Test func onlyAnInteractiveQuitOfAnInactiveAppActivates() {
        #expect(QuitCoordinator.shouldActivate(.interactive, isActive: false, noActivate: false))
        #expect(!QuitCoordinator.shouldActivate(.interactive, isActive: true, noActivate: false))
        #expect(!QuitCoordinator.shouldActivate(.interactive, isActive: false, noActivate: true))
        #expect(!QuitCoordinator.shouldActivate(.scripted, isActive: false, noActivate: false))
    }

    @Test func sigtermAnswersTheOpenDialogWithKeep() {
        let (alert, center, answers) = Self.open()
        alert.answerKeepingSessions()
        #expect(answers() == [.quit(.keep, remember: false)])
        #expect(center.records.isEmpty, "the dialog goes away")
    }

    @Test func quitDismissesEveryOtherDialogFirst() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answer: CmuxDialogAnswer?
        center.present(DestructiveConfirmation.spec(.init(title: "Close?", body: "x", button: "Close")), in: .app) { answer = $0 }
        center.dismissAll()
        #expect(answer?.isDismissal == true)
        #expect(answer?.button == "cancel")
    }

    @Test func destructiveConfirmationReturnConfirmsEscapeCancels() {
        let spec = DestructiveConfirmation.spec(.init(title: "Close Workspace?", body: "vim runs", button: "Close"))
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == .press(DestructiveConfirmation.confirmID))
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("cancel"))
    }

    @Test func renamePromptHasOneFieldWithTheCurrentName() {
        let spec = RenamePrompt.spec(title: "Rename Tab", initial: "zsh")
        #expect(spec.fields == [.text("name", initial: "zsh")])
        #expect(spec.defaultButton?.id == "rename")
    }
}
