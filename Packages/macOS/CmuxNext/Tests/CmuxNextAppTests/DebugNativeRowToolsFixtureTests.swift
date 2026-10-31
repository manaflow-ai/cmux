#if DEBUG
import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import Testing

/// Capture fixtures decode real page payloads and never change the user's native-tools setting.
@MainActor @Suite(.serialized)
struct DebugNativeRowToolsFixtureTests {
    @Test func sampleDecodesThroughThePageRequestDecoder() throws {
        let tools = try #require(DebugNativeRowToolsFixture.decode(DebugNativeRowToolsFixture.sample))
        #expect(tools.map(\.id) == ["project", "terminal", "files", "preview", "worktree", "pr", "session-info"])
        let worktree = try #require(tools.first { $0.id == "worktree" })
        #expect(worktree.menu.map(\.label) == ["Branch: fix-login", "Base: main", "Apply", "Remove"])
        let pr = try #require(tools.first { $0.id == "pr" })
        #expect(pr.menu.count == 5)
        #expect(pr.menu.first { $0.id == "pending" }?.enabled == false)
        #expect(tools.last?.toggled == true)
    }

    @Test func refusedPayloadReturnsAnErrorWithoutOpeningAPage() {
        let services = MachineIconTests.services()
        let result = DebugNativeRowToolsFixture.show(["tools": .array([.object(["id": .string("invalid")])])], services: services)
        #expect(result.objectValue?["error"]?.stringValue == "unsupported pane.tabRowTools.set: invalid tools")
        #expect(services.pages.provider(DebugNativeRowToolsFixture.pageID) == nil)
        #expect(DebugNativeRowToolsFixture.decode(.string("not an array")) == nil)
    }

    @Test func namedMenuUsesTheRealPressEntryPoint() throws {
        _ = NSApplication.shared
        let view = DebugNativeRowToolsFixtureView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.configure(tools: try #require(DebugNativeRowToolsFixture.decode(DebugNativeRowToolsFixture.sample)), width: 760)
        let button = try #require(view.menuButton("pr"))
        var titles: [String] = []
        // Replace only the blocking presentation in this test; production uses the toolbar's wrapper.
        button.presentMenu = { menu, _ in titles = menu.items.map(\.title) }
        var opened = false
        button.onMenuOpenChange = { opened = opened || $0 }
        view.pressMenu(button)
        #expect(opened)
        #expect(titles.first == "Open #123")
        #expect(!view.openMenu("missing"))
    }

    @Test func configuringTheFixtureLeavesTheUserTunableUntouched() throws {
        let before = ChromeTunables.nativeRowTools.value
        let override = TunableStore.shared.override(ChromeTunables.nativeRowTools.key)
        let view = DebugNativeRowToolsFixtureView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let tools = try #require(DebugNativeRowToolsFixture.decode(DebugNativeRowToolsFixture.sample))
        view.configure(tools: tools, width: 140)
        #expect(view.toolbar.nativeItems == tools)
        #expect(!view.toolbar.nativeOverflowItems().isEmpty)
        #expect(ChromeTunables.nativeRowTools.value == before)
        #expect(TunableStore.shared.override(ChromeTunables.nativeRowTools.key) == override)
    }
}
#endif
