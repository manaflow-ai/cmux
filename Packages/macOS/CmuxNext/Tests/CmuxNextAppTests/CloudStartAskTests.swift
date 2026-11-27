import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDesign
import Foundation
import Testing

/// A Cloud start's questions are one definition shown two ways: in the start's card, or as the cmux
/// dialog they were before where no card holds them (start-session, a chat's recovery).
@MainActor @Suite(.serialized)
struct AgentPaneCloudAskerTests {
    private func prompt() throws -> CloudCodexLoginPrompt {
        CloudCodexLoginPrompt(verificationURL: try #require(URL(string: "https://example.com/device")), userCode: "DEMO-CODE")
    }

    /// Answers each question with the next of `answers`, recording what it was asked.
    @MainActor private final class Script {
        var answers: [String?]
        var asked: [AgentPaneCloudAsk] = []
        init(_ answers: [String?]) { self.answers = answers }
        var asker: AgentPaneCloudAsker {
            AgentPaneCloudAsker { [self] question in
                asked.append(question)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
    }

    @Test func theDeviceCodeDialogKeepsItsButtonsInTheirOrder() throws {
        let spec = AgentPaneCloudAsker.spec(CloudPresenter.codexDeviceAsk(try prompt()))
        #expect(spec.buttons.map(\.id) == ["cancel", AgentPaneCloudAsker.linkButton, CloudPresenter.codexSignedIn])
        #expect(spec.buttons.map(\.role) == [.cancel, .default, .normal])
        #expect(spec.identifier == CloudPresenter.codexDeviceCodeIdentifier)
    }

    @Test func theCardShowsTheCodeAndLinksToTheSignInPage() throws {
        let ask = CloudPresenter.codexDeviceAsk(try prompt())
        #expect(ask.kind == .codexDevice && ask.code == "DEMO-CODE")
        #expect(ask.link == (try prompt()).verificationURL)
        // One filled button in the card: "I signed in"; the sign-in page is a link beside it.
        #expect(ask.buttons.filter { $0.role == "default" }.map(\.id) == [CloudPresenter.codexSignedIn])
    }

    @Test func theDialogsOpenSignInOpensThePageAndAsksAgain() async throws {
        let script = Script([AgentPaneCloudAsker.linkButton, CloudPresenter.codexSignedIn])
        var opened: [URL] = []
        #expect(await CloudPresenter.codexDeviceCode(try prompt(), asker: script.asker, open: { opened.append($0) }))
        #expect(opened == [try prompt().verificationURL])
        #expect(script.asked.count == 2 && script.asked[0].id == script.asked[1].id)
    }

    @Test func anUnansweredOrCancelledCodeSignsNothingIn() async throws {
        #expect(!(await CloudPresenter.codexDeviceCode(try prompt(), asker: Script([nil]).asker, open: { _ in Issue.record("opened") })))
        #expect(!(await CloudPresenter.codexDeviceCode(try prompt(), asker: Script(["cancel"]).asker, open: { _ in Issue.record("opened") })))
    }

    @Test func aDialogWithNoScopeAsksNothing() async throws {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let asker = AgentPaneCloudAsker.dialog({ nil }, center: center)
        #expect(await asker.ask(CloudPresenter.codexDeviceAsk(try prompt())) == nil)
        #expect(center.records.isEmpty)
    }
}
