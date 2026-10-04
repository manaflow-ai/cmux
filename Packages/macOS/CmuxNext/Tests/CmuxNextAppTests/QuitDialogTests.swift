@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// R96: the quit question is a cmux dialog (no system alert). Return quits
/// and keeps the terminals, Escape cancels, "End Sessions…" asks once more
/// in the same place and carries "Don't ask again".
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

    @Test func endSessionsAsksOnceMoreAndCarriesDontAskAgain() throws {
        let (alert, center, answers) = Self.open()
        alert.remembers = true
        #expect(alert.press("end"))
        #expect(answers().isEmpty)
        let record = try #require(center.records.first)
        #expect(center.records.count == 1)
        #expect(record.spec.buttons.map(\.id) == ["cancel", "end-keep-layout", "end-everything"])
        #expect(record.spec.buttons.last?.role == .destructive)
        #expect(alert.press("end-everything"))
        #expect(answers() == [.quit(.endEverything, remember: true)])
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
