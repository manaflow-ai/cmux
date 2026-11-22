import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// A page's console calls become `console` events and its uncaught errors
/// `pageerror` events, from every frame, as the CDP driver emits them
/// (`page.on("console")`, `page.waitForEvent("console")`, `pageerror`).
/// In DriverCallTests so every WebKit test runs serialized (DialogTests).
extension DriverCallTests {
    static let consolePage = "data:text/html," + ("""
    <title>C</title><iframe srcdoc="<script>console.info('from frame')</script>"></iframe>
    <script>window.fail = () => setTimeout(() => { throw new TypeError("boom"); });</script>
    """.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

    @Test func consoleCallsAndUncaughtErrorsBecomeEvents() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let tab = try await provider.openAutomationTab(url: nil)
        let id = tab.id.rawValue
        var collected: [DriverEvent] = []
        let reader = Task { @MainActor in
            for await event in driver.events { collected.append(event) }
        }
        defer { reader.cancel() }
        _ = try await driver.call(method: "tab.navigate", params: .object([
            "targetId": .string(id), "url": .string(Self.consolePage), "waitUntil": .string("load"), "timeoutMs": .number(15000),
        ]))
        _ = try await driver.call(method: "frame.evaluate", params: .object([
            "targetId": .string(id), "world": .string("page"),
            "source": .string("() => { console.log('lab log', 42, {a: 1}); console.warn('lab warn'); console.error('lab error'); window.fail(); return true; }"),
        ]))
        func payloads(_ name: String) -> [[String: DriverJSON]] {
            collected.compactMap { event in
                guard event.name == name, case .object(let payload) = event.payload else { return nil }
                return payload
            }
        }
        for _ in 0..<100 where payloads("pageerror").isEmpty || payloads("console").count < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let console = payloads("console").map { [$0["type"]?.stringValue ?? "", $0["text"]?.stringValue ?? ""] }
        #expect(console.contains(["info", "from frame"]))
        #expect(console.contains(["log", "lab log 42 Object"]))
        #expect(console.contains(["warning", "lab warn"]))
        #expect(console.contains(["error", "lab error"]))
        #expect(payloads("console").allSatisfy { $0["targetId"] == .string(id) })
        // The error comes from the page's own script: an error thrown by
        // injected code is muted ("Script error.").
        let error = try #require(payloads("pageerror").first)
        #expect(error["message"] == .string("boom"))
        #expect(error["stack"]?.stringValue?.hasPrefix("TypeError: boom") == true)
    }
}
