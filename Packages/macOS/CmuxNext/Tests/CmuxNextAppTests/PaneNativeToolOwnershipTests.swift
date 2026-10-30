#if DEBUG
import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
import Foundation
import Testing

/// The tools follow the page on screen, including the end of a first-paint hold without a tab-store update.
@MainActor @Suite(.serialized) struct PaneNativeToolOwnershipTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func snapshot(_ owner: PaneNativeToolOwner) -> PaneToolbar.State {
        let model = owner.model
        return PaneToolbar.State(nativeOwnerID: model.map(ObjectIdentifier.init), nativeItems: model?.tabRowTools ?? [],
                                 nativeEnabled: model?.tabRow.nativeToolsEnabled == true)
    }

    @Test func holdReleaseRebindsObservationAndIdenticalToolCallbacks() async throws {
        let store = TunableStore.shared, key = ChromeTunables.nativeRowTools.key
        store.activate(file: nil)
        store.register(DesignTunables.all)
        let previous = store.override(key)
        store.set(key, .bool(true))
        defer { store.set(key, previous) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "native-tool-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let first = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let second = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { first.close(); second.close() }
        first.model.tabRow.supportsNativeTools = true
        second.model.tabRow.supportsNativeTools = true
        first.model.markPainted()
        let tool = PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review")
        first.model.setTabRowTools([tool])
        second.model.setTabRowTools([tool])
        var firstCalls = 0, secondCalls = 0
        first.model.onTabRowToolInvoked = { _, _ in firstCalls += 1 }
        second.model.onTabRowToolInvoked = { _, _ in secondCalls += 1 }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: []), reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        pane.toolbar = toolbar
        pane.show(first)
        pane.show(second)
        try #require(pane.paintHold.kept === first)
        let owner = pane.nativeToolOwner
        let current = ObservationStream.current { snapshot(owner) }
        var updates = current.later.makeAsyncIterator()
        toolbar.apply(current.value, owner: owner)
        let oldInvocation = try #require(toolbar.view.onNativeTool)
        oldInvocation("review", nil)
        #expect(firstCalls == 1 && secondCalls == 0)

        second.model.markPainted()
        #expect(owner.model === second)
        let next = try #require(await updates.next())
        #expect(next != current.value, "identical tools still change their owner")
        toolbar.apply(next, owner: owner)
        oldInvocation("review", nil)
        toolbar.view.onNativeTool?("review", nil)
        #expect(firstCalls == 1 && secondCalls == 1, "a retained outgoing callback must not retarget to the incoming page")

        second.model.setTabRowTools([])
        let changed = try #require(await updates.next())
        #expect(changed.nativeItems.isEmpty, "observation must now subscribe to the incoming model")
        toolbar.apply(changed, owner: owner)
        #expect(toolbar.view.nativeButtons.isEmpty)
        pane.detachContent()
        let detached = try #require(await updates.next())
        #expect(detached.nativeOwnerID == nil && detached.nativeItems.isEmpty)
        toolbar.apply(detached, owner: owner)
        #expect(toolbar.view.nativeButtons.isEmpty)
    }
}
#endif
