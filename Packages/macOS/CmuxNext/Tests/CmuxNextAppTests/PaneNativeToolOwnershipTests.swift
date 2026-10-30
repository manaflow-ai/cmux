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
    private nonisolated struct UpdateTimedOut: Error, CustomStringConvertible {
        let label: String
        var description: String { "Timed out after 2 seconds waiting for \(label)" }
    }

    @MainActor private final class UpdateIterator {
        var iterator: ObservationStream<PaneToolbar.State>.Iterator

        init(_ iterator: ObservationStream<PaneToolbar.State>.Iterator) { self.iterator = iterator }

        func next() async -> PaneToolbar.State? {
            var pending = iterator
            let value = await pending.next()
            iterator = pending
            return value
        }
    }

    private func nextUpdate(_ updates: UpdateIterator, label: String) async throws -> PaneToolbar.State {
        try await withThrowingTaskGroup(of: PaneToolbar.State?.self) { group in
            group.addTask { await updates.next() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw UpdateTimedOut(label: label)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next(), let value else { throw UpdateTimedOut(label: label) }
            return value
        }
    }

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
        let owner = pane.nativeToolOwner
        #expect(owner.model === first.model, "the initially shown page owns the tools")
        let current = ObservationStream.current { snapshot(owner) }
        let updates = UpdateIterator(current.later.makeAsyncIterator())
        toolbar.apply(current.value, owner: owner)
        let oldInvocation = try #require(toolbar.view.onNativeTool)
        oldInvocation("review", nil)
        #expect(firstCalls == 1 && secondCalls == 0)

        pane.show(second)
        try #require(pane.paintHold.kept === first)
        let switched = try await nextUpdate(updates, label: "selected page ownership")
        #expect(switched.nativeOwnerID == ObjectIdentifier(second.model), "owner observation follows the selected page")
        #expect(owner.model === second.model, "the selected incoming page owns tools during the paint hold")
        toolbar.apply(switched, owner: owner)
        let incomingInvocation = try #require(toolbar.view.onNativeTool)
        incomingInvocation("review", nil)
        #expect(firstCalls == 1 && secondCalls == 1, "a fresh callback during the hold reaches the incoming page")
        oldInvocation("review", nil)
        #expect(firstCalls == 1 && secondCalls == 1, "the retained outgoing callback is rejected after ownership changes; it cannot retarget")

        second.model.markPainted()
        #expect(owner.model === second.model, "releasing the hold does not change the selected owner")
        toolbar.view.onNativeTool?("review", nil)
        #expect(firstCalls == 1 && secondCalls == 2, "the current callback remains on the incoming page")

        second.model.setTabRowTools([])
        let changed = try await nextUpdate(updates, label: "incoming page tools")
        #expect(changed.nativeItems.isEmpty, "observation must now subscribe to the incoming model")
        toolbar.apply(changed, owner: owner)
        #expect(toolbar.view.nativeButtons.isEmpty)
        pane.detachContent()
        let detached = try await nextUpdate(updates, label: "detached ownership")
        #expect(detached.nativeOwnerID == nil && detached.nativeItems.isEmpty)
        toolbar.apply(detached, owner: owner)
        #expect(toolbar.view.nativeButtons.isEmpty)

        pane.show(second)
        try #require(second.superview === pane.contentHost)
        second.removeFromSuperview()
        #expect(owner.model == nil, "reparenting content away clears native tool ownership")
    }

    @Test func pruningParkedViewAdoptedByAnotherPanePreservesItsNewHook() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "adopted-native-tool-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { page.close() }
        page.model.markPainted()
        let firstPane = PaneContentView(stripModel: TabStripModel(tabs: []), reveal: LaunchReveal(deadline: .zero))
        let replacement = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        replacement.model.markPainted()
        defer { replacement.close() }
        firstPane.show(page)
        firstPane.show(replacement)
        #expect(firstPane.parked.contains { $0.view === page })

        let secondPane = PaneContentView(stripModel: TabStripModel(tabs: []), reveal: LaunchReveal(deadline: .zero))
        secondPane.show(page)
        try #require(page.onNativeToolOwnerChange != nil)
        firstPane.prunePark()

        #expect(page.onNativeToolOwnerChange != nil, "pruning the old pane must not clear the adopted pane's hook")
        page.removeFromSuperview()
        #expect(secondPane.nativeToolOwner.model == nil, "the preserved hook clears the adopting pane when the page leaves")
    }

    @Test func closingShownViewClearsOwnerHookWithoutRebindingPane() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "closed-native-tool-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let pane = PaneContentView(stripModel: TabStripModel(tabs: []), reveal: LaunchReveal(deadline: .zero))
        pane.show(page)
        let owner = pane.nativeToolOwner
        let ownerBeforeClose = try #require(owner.model)
        #expect(page.onNativeToolOwnerChange != nil)

        page.close()

        #expect(page.onNativeToolOwnerChange == nil, "a closed page must not retain the pane callback")
        #expect(owner.model === ownerBeforeClose, "closing the page must not rebind the pane owner")
    }
}
#endif
