import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Foundation
@testable import MessagesLabHome
import CmuxNextTestSupport
import Testing

/// A chat with history (the first-run panel is hidden) in a pane width change: no label below the transcript view
/// draws its glyphs again; the failure names each one that does (`LabelRedraws`, HomeResizeChromeWasteTests).
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeResizeHistoryLabelTests {
    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @Test func aWidthChangeOfAChatWithHistoryDrawsNoLabelAgain() async throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = 400
        let store = HomeStore(source: GatedHomeSource(MockHomeSource(options: options)))
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        let me = try #require(store.me?.id)

        let window = LabelRedraws.window()
        defer { window.closeAfterTest() }
        let view = HomeNativeTranscriptView(store: store, conversation: Self.conversation, me: me)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 700)
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        await until { !store.transcript(for: Self.conversation).isEmpty }
        for _ in 0..<2_000 { await Task.yield() }

        let result = LabelRedraws.redrawn(in: view, widths: LabelRedraws.widths) {
            view.transcript.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            view.transcript.controller.demo?.collection.layoutIfNeeded()
            LabelRedraws.show(window)
        }
        let messages = view.transcript.controller.demo?.store.state.conversation.messages.count ?? 0
        #expect(messages > 0, "SETUP: the chat shows its first page")
        #expect(view.firstRun.isHidden, "SETUP: a chat with messages hides the first-run panel")
        #expect(result.drewAtFirst > 0, "SETUP: this test's display pass draws labels (\(LabelRedraws.labels(in: view).count) below the chat)")
        #expect(result.names.isEmpty, "labels drawn again in 6 width changes of a chat with \(messages) messages: \(result.names.joined(separator: "; "))")
    }
}
