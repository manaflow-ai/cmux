@testable import CmuxNextApp
import Foundation
import Testing

/// Guided CSV import (PASSWORDS-IMPORT-ANY-BROWSER): Safari / Apple Passwords,
/// 1Password and Bitwarden show their export steps before the open panel; a CSV
/// the person already has goes straight to the panel; a cancel at any step
/// picks no file.
@MainActor struct PasswordCSVGuideTests {
    enum Event: Equatable {
        case chooseSource
        case steps(PasswordCSVSource)
        case openApp(PasswordCSVSource)
        case chooseFile(PasswordCSVSource)
    }

    @MainActor final class Script: PasswordCSVGuidePresenting {
        var source: PasswordCSVSource?
        var answers: [PasswordCSVStepAnswer]
        var file: URL?
        var events: [Event] = []

        init(source: PasswordCSVSource?, answers: [PasswordCSVStepAnswer] = [], file: URL? = URL(fileURLWithPath: "/tmp/passwords.csv")) {
            self.source = source
            self.answers = answers
            self.file = file
        }

        func chooseSource() async -> PasswordCSVSource? {
            events.append(.chooseSource)
            return source
        }

        func showSteps(_ source: PasswordCSVSource) async -> PasswordCSVStepAnswer {
            events.append(.steps(source))
            return answers.isEmpty ? .cancel : answers.removeFirst()
        }

        func openApp(_ source: PasswordCSVSource) {
            events.append(.openApp(source))
        }

        func chooseFile(_ source: PasswordCSVSource) async -> URL? {
            events.append(.chooseFile(source))
            return file
        }
    }

    @Test func aCSVThePersonHasGoesStraightToTheOpenPanel() async {
        let script = Script(source: .other)
        #expect(await PasswordCSVGuide(presenter: script).run() == URL(fileURLWithPath: "/tmp/passwords.csv"))
        #expect(script.events == [.chooseSource, .chooseFile(.other)])
    }

    @Test func applePasswordsShowsTheStepsAndCanOpenPasswordsFirst() async {
        let script = Script(source: .apple, answers: [.openApp, .chooseFile])
        #expect(await PasswordCSVGuide(presenter: script).run() != nil)
        #expect(script.events == [.chooseSource, .steps(.apple), .openApp(.apple), .steps(.apple), .chooseFile(.apple)])
    }

    @Test(arguments: [PasswordCSVSource.onePassword, .bitwarden])
    func passwordManagersShowTheirStepsBeforeTheOpenPanel(_ source: PasswordCSVSource) async {
        let script = Script(source: source, answers: [.chooseFile])
        #expect(await PasswordCSVGuide(presenter: script).run() != nil)
        #expect(script.events == [.chooseSource, .steps(source), .chooseFile(source)])
    }

    @Test func aCancelAtAnyStepPicksNoFile() async {
        let none = Script(source: nil)
        #expect(await PasswordCSVGuide(presenter: none).run() == nil)
        #expect(none.events == [.chooseSource])

        let steps = Script(source: .bitwarden, answers: [.cancel])
        #expect(await PasswordCSVGuide(presenter: steps).run() == nil)
        #expect(steps.events == [.chooseSource, .steps(.bitwarden)])

        let panel = Script(source: .onePassword, answers: [.chooseFile], file: nil)
        #expect(await PasswordCSVGuide(presenter: panel).run() == nil)
    }
}
