import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextDesign
import Testing

#if DEBUG
/// cx-t2rz: the Cloud machine create confirmation is the person's spend
/// approval (it lets the app answer a G8 approval). An agent with the DEBUG
/// socket (`debug.dialog`) may dismiss it, which declines, but never press
/// Create, set a field or send a key to it.
@MainActor @Suite(.serialized) struct CloudCreateConfirmAutomationTests {
    @Test func automationCannotPressCreateButMayDismiss() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var answers: [Bool] = []
        let center = CmuxDialogCenter.shared
        CloudPresenter.confirm("Create a Cloud machine?", "body", button: "Create", identifier: CloudPresenter.createConfirmIdentifier,
                               in: window) { answers.append($0) }
        let id = try #require(center.records.last { $0.spec.identifier == CloudPresenter.createConfirmIdentifier }?.id)
        defer { _ = center.dismiss(id) }
        let services = ActionBindingCoverageTests.boundServices()

        for params: [String: JSONValue] in [["id": .number(Double(id)), "press": .string("confirm")],
                                            ["id": .number(Double(id)), "key": .string("return")],
                                            ["id": .number(Double(id)), "set": .object(["x": .bool(true)])]] {
            let reply = DebugDialog.run(params, services)
            #expect(reply.objectValue?["error"]?.stringValue == "this dialog answers only to the user", "\(params)")
        }
        #expect(answers.isEmpty, "nothing answered the sheet")
        #expect(center.record(id) != nil, "the sheet is still open")

        _ = DebugDialog.run(["id": .number(Double(id)), "dismiss": .bool(true)], services)
        #expect(center.record(id) == nil)
        #expect(answers == [false], "a dismiss declines: \(answers)")
    }
}
#endif
