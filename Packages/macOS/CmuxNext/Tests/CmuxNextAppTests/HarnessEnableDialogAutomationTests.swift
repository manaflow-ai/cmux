import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Testing

#if DEBUG
/// BRING-YOUR-OWN-HARNESS H4: the Enable harness sheet answers only to the user. An agent with the
/// DEBUG socket (`debug.dialog`) may dismiss it, which refuses, but never press Enable, set a
/// field or send a key to it: that would run a folder's program with the user's rights.
@MainActor @Suite(.serialized) struct HarnessEnableDialogAutomationTests {
    @Test func automationCannotPressEnableButMayDismiss() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let prompt = AgentPaneHarnessEnablePrompt(id: "repo-agent", folder: "/repo", path: "/repo/.cmux/harnesses/repo-agent.toml",
                                                  argv: ["node", "agent.js"], program: "/usr/local/bin/node", env: [],
                                                  checkedFiles: [], warnings: [], sha256: "c0ffee")
        var answers: [String?] = []
        let center = CmuxDialogCenter.shared
        let id = center.present(AgentPaneView.harnessEnableSpec(prompt), in: .window(window)) { answers.append($0.button) }
        defer { _ = center.dismiss(id) }
        let services = ActionBindingCoverageTests.boundServices()

        for params: [String: JSONValue] in [["id": .number(Double(id)), "press": .string("enable")],
                                            ["id": .number(Double(id)), "key": .string("return")],
                                            ["id": .number(Double(id)), "set": .object(["x": .bool(true)])]] {
            let reply = DebugDialog.run(params, services)
            #expect(reply.objectValue?["error"]?.stringValue == "this dialog answers only to the user", "\(params)")
        }
        #expect(answers.isEmpty, "nothing answered the sheet")
        #expect(center.record(id) != nil, "the sheet is still open")

        _ = DebugDialog.run(["id": .number(Double(id)), "dismiss": .bool(true)], services)
        #expect(center.record(id) == nil)
        #expect(answers.count == 1 && answers[0] != "enable", "a dismiss is a refusal: \(answers)")
    }
}
#endif
