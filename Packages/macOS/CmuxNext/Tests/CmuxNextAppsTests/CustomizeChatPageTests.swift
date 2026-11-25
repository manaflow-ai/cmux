@testable import CmuxNextApps
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The agent chat's Customize bar (`cmux.customize.run`): each verb becomes the CLI's words, an
/// argument the verb does not take is refused before the CLI runs, and a refusal's envelope reaches
/// the page as the answer.
@MainActor
struct CustomizeChatPageTests {
    private func params(_ verb: String, _ arg: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["verb": .string(verb)]
        if let arg { object["arg"] = .string(arg) }
        return .object(object)
    }

    @Test func verbsBecomeTheCLIWords() {
        #expect(CustomizeChatPage.arguments(params("status")) == ["--json", "customize", "status"])
        #expect(CustomizeChatPage.arguments(params("rollback")) == ["--json", "customize", "rollback"])
        #expect(CustomizeChatPage.arguments(params("rollback", "12")) == ["--json", "customize", "rollback", "12"])
        #expect(CustomizeChatPage.arguments(params("save", "night-owl")) == ["--json", "customize", "save", "night-owl"])
        #expect(CustomizeChatPage.arguments(params("apply", "-denser")) == ["--json", "customize", "apply", "--", "-denser"])
    }

    @Test func refusesWhatTheBarNeverSends() {
        #expect(CustomizeChatPage.arguments(params("ask", "make it blue")) == nil)
        #expect(CustomizeChatPage.arguments(params("status", "x")) == nil)
        #expect(CustomizeChatPage.arguments(params("rollback", "1; rm")) == nil)
        #expect(CustomizeChatPage.arguments(params("save", "../x")) == nil)
        #expect(CustomizeChatPage.arguments(params("save", "Night")) == nil)
        #expect(CustomizeChatPage.arguments(params("use")) == nil)
        #expect(CustomizeChatPage.arguments(.object([:])) == nil)
    }

    @Test func answersTheCLIJSONAndItsRefusal() async throws {
        let ok = CustomizeChatPage(cli: { URL(fileURLWithPath: "/bin/cmux") }, runCLI: { _, words in
            (0, Data(#"{"ok":true,"verb":"\#(words[2])"}"#.utf8), Data())
        })
        let answer = try await ok.call(CustomizeChatPage.op, params: params("discard"), context: PageCallContext(page: "cmux.agent"))
        #expect(answer["verb"]?.stringValue == "discard")

        let refused = CustomizeChatPage(cli: { URL(fileURLWithPath: "/bin/cmux") }, runCLI: { _, _ in
            (1, Data(), Data(#"{"ok":false,"error":{"code":"customize.invalid"}}"#.utf8))
        })
        let envelope = try await refused.call(CustomizeChatPage.op, params: params("apply"), context: PageCallContext(page: "cmux.agent"))
        #expect(envelope["error"]?["code"]?.stringValue == "customize.invalid")

        let none = CustomizeChatPage(cli: { nil })
        await #expect(throws: PageError.self) {
            _ = try await none.call(CustomizeChatPage.op, params: params("status"), context: PageCallContext(page: "cmux.agent"))
        }
    }
}
