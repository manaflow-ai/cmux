import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// A page's confirm() becomes dialog.opened, stays open until dialog.respond,
/// and the page gets the answer.
/// In DriverCallTests so every WebKit test runs serialized: a page's
/// modal dialog blocks the web process other tabs share.
extension DriverCallTests {
    @Test func confirmOpensAnEventAndTakesTheAnswer() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let tab = try await provider.openAutomationTab(url: nil)
        let id = tab.id.rawValue
        _ = try await driver.call(method: "tab.navigate", params: .object([
            "targetId": .string(id), "url": .string("data:text/html,<title>D</title>"), "timeoutMs": .number(15000),
        ]))
        var collected: [DriverEvent] = []
        let reader = Task { @MainActor in
            for await event in driver.events { collected.append(event) }
        }
        defer { reader.cancel() }
        // confirm() blocks the evaluation until the dialog is answered.
        let pending = Task { @MainActor in
            try await driver.call(method: "frame.evaluate", params: .object([
                "targetId": .string(id), "world": .string("page"),
                "source": .string("() => { window.answer = confirm('Proceed?'); return window.answer; }"),
            ]))
        }
        var opened: [String: DriverJSON]?
        for _ in 0..<200 where opened == nil {
            try await Task.sleep(for: .milliseconds(50))
            for event in collected where event.name == "dialog.opened" {
                if case .object(let payload) = event.payload { opened = payload }
            }
        }
        let payload = try #require(opened)
        #expect(payload["type"] == .string("confirm") && payload["message"] == .string("Proceed?"))
        let dialogID = try #require(payload["dialogId"]?.stringValue)
        _ = try await driver.call(method: "dialog.respond", params: .object([
            "targetId": .string(id), "dialogId": .string(dialogID), "accept": .bool(true),
        ]))
        #expect(try await pending.value == .bool(true))
        await #expect(throws: DriverError(.notFound, "Dialog \(dialogID) is gone")) {
            try await driver.call(method: "dialog.respond", params: .object([
                "targetId": .string(id), "dialogId": .string(dialogID), "accept": .bool(true),
            ]))
        }
    }
}
