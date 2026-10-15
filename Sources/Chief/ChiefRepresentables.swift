import AppKit
import CmuxHomeCore
import SwiftUI

/// Home in SwiftUI: the conversation list and the selected Chief
/// conversation (``ChiefHomeView``).
struct ChiefHomeRepresentable: NSViewRepresentable {
    /// Whether Home is the page the user sees now. A Home kept mounted
    /// behind the workspaces passes false, so it sends no read receipts.
    var isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    func makeNSView(context: Context) -> ChiefHomeView {
        let view = ChiefHomeView()
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: ChiefHomeView, context: Context) {
        let becameActive = isActive && !view.isActive
        view.isActive = isActive
        if becameActive { view.focusComposer() }
    }

    static func dismantleNSView(_ view: ChiefHomeView, coordinator: ()) {
        view.stop()
    }
}

/// A Chief tab in a workspace pane: one conversation (the panel's, else the
/// default Chief's), focused when the panel asks.
struct ChiefPanelView: NSViewRepresentable {
    @ObservedObject var panel: ChiefPanel

    init(panel: ChiefPanel) {
        self.panel = panel
    }

    func makeNSView(context: Context) -> ChiefPanelHostView {
        let view = ChiefPanelHostView(conversation: panel.conversationID, focusGeneration: panel.focusRequestGeneration)
        // The panel remembers the conversation (session restore); the next update shows it.
        view.onOpenConversation = { [weak panel] id in panel?.conversationID = id }
        return view
    }

    func updateNSView(_ view: ChiefPanelHostView, context: Context) {
        view.show(panel.conversationID)
        view.requestFocus(generation: panel.focusRequestGeneration)
    }

    static func dismantleNSView(_ view: ChiefPanelHostView, coordinator: ()) {
        view.stop()
    }
}

/// The AppKit side of ``ChiefPanelView``: swaps its ``ChiefTranscriptView``
/// when the panel's conversation changes and focuses the message box on
/// each new focus request.
@MainActor
final class ChiefPanelHostView: NSView {
    private(set) var transcript: ChiefTranscriptView?
    private var conversation: ConversationID?
    private var focusGeneration: Int
    private var stopped = false
    /// A new conversation was started from this tab's settings panel.
    var onOpenConversation: (ConversationID) -> Void = { _ in }

    init(conversation: ConversationID?, focusGeneration: Int) {
        self.focusGeneration = focusGeneration
        super.init(frame: .zero)
        place(conversation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        transcript.map { window?.makeFirstResponder($0.primaryInput) ?? false } ?? false
    }

    /// Shows `conversation` (nil: the default Chief's) when it changed.
    func show(_ conversation: ConversationID?) {
        guard !stopped, conversation != self.conversation else { return }
        place(conversation)
    }

    /// Focuses the message box when `generation` is a new request.
    func requestFocus(generation: Int) {
        guard generation != focusGeneration else { return }
        focusGeneration = generation
        focusComposer()
    }

    /// Puts the keyboard in the message box.
    func focusComposer() {
        transcript?.focusComposer()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        transcript?.stop()
    }

    private func place(_ conversation: ConversationID?) {
        self.conversation = conversation
        transcript?.stop()
        transcript?.removeFromSuperview()
        let view = ChiefTranscriptView(conversation: conversation)
        // A new conversation started from this tab's settings opens in this tab.
        view.onOpenConversation = { [weak self] id in self?.onOpenConversation(id) }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        transcript = view
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pane appeared: a pending focus request lands now.
        if window != nil, window?.firstResponder === self { focusComposer() }
    }
}
