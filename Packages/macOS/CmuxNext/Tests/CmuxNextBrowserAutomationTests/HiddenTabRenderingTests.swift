import AppKit
import CmuxNextBrowser
import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowserAutomation

/// A tab no pane shows has no window, so WebKit takes no trusted input,
/// pauses animation frames and returns no snapshot. Before a call on a tab
/// the driver asks the App to keep the tab rendering (`keepRendering`).
/// Before, a background agent tab failed `input.mouse: the tab is not in a
/// window` and every locator.click timed out.
@MainActor
@Suite(.serialized) struct HiddenTabRenderingTests {
    final class RenderingProvider: AutomationTabProvider {
        let inner = DriverCallTests.FakeProvider()
        var kept: [BrowserTabID] = []
        var windows: [NSWindow] = []

        func automationTabs(all: Bool) -> [AutomationTab] { inner.automationTabs(all: all) }
        func openAutomationTab(url: URL?) async throws -> WebKitTab { try await inner.openAutomationTab(url: url) }
        func closeAutomationTab(_ id: BrowserTabID) { inner.closeAutomationTab(id) }
        func endSessionTab(_ id: String) -> Bool { inner.endSessionTab(id) }
        func activateAutomationTab(_ id: BrowserTabID) {}

        func keepRendering(_ tab: WebKitTab) async -> Bool {
            kept.append(tab.id)
            guard tab.webView.window == nil else { return false }
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            tab.contentView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(tab.contentView)
            windows.append(window)
            return true
        }
    }

    @Test func aHiddenTabIsKeptRenderingBeforeInput() async throws {
        let provider = RenderingProvider()
        let driver = WebKitDriver(provider: provider)
        let opened = try await driver.call(method: "tabs.open", params: .object([:]))
        guard case .object(let fields) = opened, case .string(let id)? = fields["targetId"] else {
            Issue.record("tabs.open returned \(opened)")
            return
        }
        let tab = try #require(provider.inner.tabs.first)
        #expect(tab.webView.window == nil, "a background tab starts with no window")
        _ = try await driver.call(method: "input.mouse", params: .object([
            "targetId": .string(id), "type": .string("move"), "x": .number(10), "y": .number(10),
        ]))
        #expect(provider.kept.contains(tab.id))
        #expect(tab.webView.window != nil)
        provider.windows.forEach { $0.close() }
    }
}
