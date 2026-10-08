import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// Navigation edges from review: same-document navigations, failures and
/// timeout 0 resolve as Playwright's do, a second driver on a tab does not
/// crash, and input that would show native UI is refused.
/// In DriverCallTests so every WebKit test runs serialized: a page's
/// modal dialog blocks the web process other tabs share.
extension DriverCallTests {
    private func navigate(_ driver: WebKitDriver, _ id: String, _ url: String, timeout: Double = 15000) async throws -> DriverJSON {
        try await driver.call(method: "tab.navigate", params: .object([
            "targetId": .string(id), "url": .string(url), "waitUntil": .string("load"), "timeoutMs": .number(timeout),
        ]))
    }

    @Test func fragmentNavigationResolvesWithoutANewDocument() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let id = try await provider.openAutomationTab(url: nil).id.rawValue
        let page = "data:text/html,<title>F</title><p id=a>a</p>"
        _ = try await navigate(driver, id, page)
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await navigate(driver, id, page + "#a", timeout: 5000)
        #expect(clock.now - started < .seconds(4))
    }

    @Test func aFailedNavigationFailsBeforeItsDeadline() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let id = try await provider.openAutomationTab(url: nil).id.rawValue
        let error = await #expect(throws: DriverError.self) {
            try await navigate(driver, id, "http://127.0.0.1:9/refused", timeout: 20000)
        }
        #expect(error?.code == .invalid)
    }

    @Test func invalidURLsAndRightClicksAreRefused() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        await #expect(throws: DriverError(.invalid, "tabs.open: Cannot navigate to invalid URL not a url")) {
            try await driver.call(method: "tabs.open", params: .object(["url": .string("not a url")]))
        }
        let id = try await provider.openAutomationTab(url: nil).id.rawValue
        let error = await #expect(throws: DriverError.self) {
            try await driver.call(method: "input.mouse", params: .object([
                "targetId": .string(id), "type": .string("down"), "x": .number(1), "y": .number(1), "button": .string("right"),
            ]))
        }
        #expect(error?.code == .unsupported)
    }

    @Test func aSecondDriverOnTheSameTabReinstallsCleanly() async throws {
        let provider = FakeProvider()
        let tab = try await provider.openAutomationTab(url: nil)
        let id = tab.id.rawValue
        let first = WebKitDriver(provider: provider)
        _ = try await navigate(first, id, "data:text/html,<title>1</title>")
        let second = WebKitDriver(provider: provider)
        _ = try await navigate(second, id, "data:text/html,<title>2</title>")
        second.detach()
        let reporters = tab.webView.configuration.userContentController.userScripts.filter { $0.source == AgentWorld.loadStateSource }
        #expect(reporters.isEmpty)
    }
}
