import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// With no header (Debug Settings > Home > Avatar and name over the chat off), the top-right panel toggles (#22702) arrive after the chat's
/// first layout (`HomeHostView.watchHeaderPanels`), and the rows' top moves under them. The
/// first-run panel follows, or it would sit over the toggles' lower part and take their clicks.
@MainActor @Suite(.serialized) struct HomeBareTopFirstRunTests {
    @Test func theFirstRunPanelMovesUnderTogglesThatArriveAfterLayout() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, .bool(false))
        defer { TunableStore.shared.set(HomeTunables.chatHeader.key, nil) }
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_bare_top"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        try #require(view.transcript.controller.host.bareTop, "the chat has no header with the tunable off")
        #expect(view.firstRun.frame.minY == HostView.bareTopInset)

        view.setHeaderPanels([HomeHeaderPanelItem(id: "memory", symbol: "brain", label: "Memory Inspector", isOn: false)])
        container.layoutSubtreeIfNeeded()
        let rowsTop = PaneHeaderView.bareAccessoryTop + HomeHeaderPanelBar.buttonSize + 8
        #expect(view.headerHeight == rowsTop)
        #expect(view.firstRun.frame.minY == rowsTop)

        view.setHeaderPanels([])
        container.layoutSubtreeIfNeeded()
        #expect(view.firstRun.frame.minY == HostView.bareTopInset)
    }
}
