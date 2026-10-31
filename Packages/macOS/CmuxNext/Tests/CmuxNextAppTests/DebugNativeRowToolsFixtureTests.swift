#if DEBUG
import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import Testing
import XCTest

/// Capture fixtures decode real page payloads and use a removable overlay, never a page-store tab.
@MainActor @Suite(.serialized)
struct DebugNativeRowToolsFixtureTests {
    private func window() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return (window, content)
    }

    @Test func sampleDecodesThroughThePageRequestDecoder() throws {
        let sample = DebugNativeRowToolsSample()
        let tools = try #require(sample.decode(sample.tools))
        #expect(tools.map(\.id) == ["project", "terminal", "files", "preview", "worktree", "pr", "session-info"])
        let worktree = try #require(tools.first { $0.id == "worktree" })
        #expect(worktree.menu.map(\.label) == ["Branch: fix-login", "Base: main", "Apply", "Remove"])
        let pr = try #require(tools.first { $0.id == "pr" })
        #expect(pr.menu.count == 5)
        #expect(pr.menu.first { $0.id == "pending" }?.enabled == false)
        #expect(tools.last?.toggled == true)
        // The raw fixture keeps the text and URL values for the decoder/rendering dependency (#28566).
        let raw = try #require(sample.tools.arrayValue)
        let rawWorktree = try #require(raw.first { $0["id"]?.stringValue == "worktree" })
        #expect(rawWorktree["text"]?.stringValue == "fix-login")
        let rawPR = try #require(raw.first { $0["id"]?.stringValue == "pr" })
        #expect(rawPR["text"]?.stringValue == "#123 ✓3/5")
        let rows = try #require(rawPR["menu"]?.arrayValue)
        #expect(rows.first { $0["id"]?.stringValue == "open" }?["url"]?.stringValue == "https://example.com/pull/123")
        #expect(rows.first { $0["id"]?.stringValue == "passing" }?["url"]?.stringValue == "https://example.com/checks/1")
        #expect(rows.first { $0["id"]?.stringValue == "failing" }?["url"]?.stringValue == "https://example.com/checks/2")
        let pending = try #require(rows.first { $0["id"]?.stringValue == "pending" })
        #expect(pending["url"] == nil)
        #expect(pending["enabled"]?.boolValue == false)
    }

    @Test func refusedPayloadRemovesOnlyTheFixtureOverlay() {
        let (window, content) = window()
        defer { window.close() }
        let original = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        content.addSubview(original)
        _ = DebugNativeRowToolsFixture.run([:], in: window)
        #expect(content.subviews.contains { $0 is DebugNativeRowToolsFixtureView })
        let result = DebugNativeRowToolsFixture.run(["tools": .array([.object(["id": .string("invalid")])])], in: window)
        #expect(result.objectValue?["error"]?.stringValue == "unsupported pane.tabRowTools.set: invalid tools")
        #expect(content.subviews.contains(original))
        #expect(!content.subviews.contains { $0 is DebugNativeRowToolsFixtureView })
    }

    @Test func successfulFixtureIsTransientAndDismissRestoresPresentation() {
        let (window, content) = window()
        defer { window.close() }
        let original = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        content.addSubview(original)
        let before = content.subviews
        let responder = window.firstResponder
        let tunable = ChromeTunables.nativeRowTools.value
        let override = TunableStore.shared.override(ChromeTunables.nativeRowTools.key)
        let result = DebugNativeRowToolsFixture.run([:], in: window)
        #expect(result.objectValue?["ok"]?.boolValue == true)
        #expect(content.subviews.contains(original))
        #expect(content.subviews.contains { $0 is DebugNativeRowToolsFixtureView })
        let updated = DebugNativeRowToolsFixture.run(["width": .number(140)], in: window)
        #expect(updated.objectValue?["ok"]?.boolValue == true)
        #expect(content.subviews.filter { $0 is DebugNativeRowToolsFixtureView }.count == 1)
        let dismissed = DebugNativeRowToolsFixture.run(["dismiss": .bool(true)], in: window)
        #expect(dismissed.objectValue?["ok"]?.boolValue == true)
        #expect(content.subviews.count == before.count)
        #expect(zip(content.subviews, before).allSatisfy { pair in pair.0 === pair.1 })
        #expect(window.contentView === content)
        #expect(window.firstResponder === responder)
        #expect(ChromeTunables.nativeRowTools.value == tunable)
        #expect(TunableStore.shared.override(ChromeTunables.nativeRowTools.key) == override)
        #expect(!content.subviews.contains { $0 is DebugNativeRowToolsFixtureView })
    }

    @Test func configuringTheFixtureLeavesTheUserTunableUntouched() throws {
        let before = ChromeTunables.nativeRowTools.value
        let override = TunableStore.shared.override(ChromeTunables.nativeRowTools.key)
        let view = DebugNativeRowToolsFixtureView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let tools = try #require(DebugNativeRowToolsSample().decode(DebugNativeRowToolsSample().tools))
        view.configure(tools: tools, width: 140)
        #expect(view.toolbar.nativeItems == tools)
        #expect(!view.toolbar.nativeOverflowItems().isEmpty)
        #expect(ChromeTunables.nativeRowTools.value == before)
        #expect(TunableStore.shared.override(ChromeTunables.nativeRowTools.key) == override)
    }

    @Test func scheduledMenuPressUsesTheProductionRevealHold() async throws {
        _ = NSApplication.shared
        let presented = XCTestExpectation(description: "scheduled fixture menu opened")
        let view = DebugNativeRowToolsFixtureView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.menuPresentationOverride = nil; view.cancelPendingMenu(); window.close() }
        let tools = try #require(DebugNativeRowToolsSample().decode(DebugNativeRowToolsSample().tools))
        view.configure(tools: tools, width: 760)
        var heldWhilePresented = false
        var titles: [String] = []
        view.menuPresentationOverride = { menu, _ in
            heldWhilePresented = view.toolbar.reveal.state.holds > 0
            titles = menu.items.map(\.title)
            presented.fulfill()
        }
        #expect(view.openMenu("pr"))
        #expect(titles.isEmpty, "the RPC returns before the menu opens")
        let result = await XCTWaiter.fulfillment(of: [presented], timeout: 2)
        #expect(result == .completed, "the scheduled menu must open within two seconds")
        #expect(titles.first == "Open #123")
        #expect(heldWhilePresented)
        #expect(view.toolbar.reveal.state.holds == 0)
    }
}
#endif
