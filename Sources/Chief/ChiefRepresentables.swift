import AppKit
import CmuxFoundation
import CmuxHomeCore
import SwiftUI

/// Home's transcript in the content area: the window's one ``ChiefHomeView``.
///
/// The window owns the view (`ContentView` keeps it while Chief is on), so
/// leaving and re-entering Home keeps the draft and the scroll position, and
/// the sidebar's list (``ChiefConversationListRepresentable``) shares its selection.
struct ChiefHomeRepresentable: NSViewRepresentable {
    let home: ChiefHomeView
    /// Whether Home is the page the user sees now. A Home kept mounted
    /// behind the workspaces passes false, so it sends no read receipts.
    var isActive: Bool

    func makeNSView(context: Context) -> ChiefHomeView {
        // SwiftUI may unmount and mount the window's one Home again.
        home.resumeIfTornDown()
        home.isActive = isActive
        return home
    }

    func updateNSView(_ view: ChiefHomeView, context: Context) {
        // Focus follows `cmuxChiefHomeDidActivate` (ChiefHomeView), first entry included.
        view.isActive = isActive
    }

    /// Home left the window (window closed, Chief turned off): stop streaming
    /// now rather than whenever, and on whichever thread, the view is freed.
    static func dismantleNSView(_ view: ChiefHomeView, coordinator: ()) {
        view.teardown()
    }
}

/// Home's conversation list in the left sidebar, under the Chief row, while
/// Home is selected. It sits on the sidebar's material and takes the
/// sidebar's content appearance and the cmux accent.
struct ChiefConversationListRepresentable: NSViewRepresentable {
    let home: ChiefHomeView
    let accent: CmuxAccentColor

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> ChiefConversationListView {
        apply(to: home.list)
        return home.list
    }

    func updateNSView(_ view: ChiefConversationListView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ChiefConversationListView) {
        view.apply(isDark: colorScheme == .dark, accent: accent.nsColor(for: colorScheme))
    }
}

/// A Chief tab in a workspace pane: one conversation (the panel's, else the
/// default Chief's), focused when the panel asks.
struct ChiefPanelView: NSViewRepresentable {
    @ObservedObject var panel: ChiefPanel
    let tabManager: TabManager?
    let isFocused: Bool
    let isVisibleInUI: Bool

    init(panel: ChiefPanel, tabManager: TabManager? = nil, isFocused: Bool, isVisibleInUI: Bool) {
        self.panel = panel
        self.tabManager = tabManager
        self.isFocused = isFocused
        self.isVisibleInUI = isVisibleInUI
    }

    func makeNSView(context: Context) -> ChiefPanelHostView {
        let view = ChiefPanelHostView(conversation: panel.conversationID)
        // The panel remembers the conversation (session restore); the next update shows it.
        view.onOpenConversation = { [weak tabManager, weak panel] id in
            if let tabManager {
                _ = ChiefHomeNavigation.openConversation(id, in: tabManager)
            } else if panel?.isHome != true {
                panel?.conversationID = id
            }
        }
        view.updatePresentation(visible: isVisibleInUI, focused: isFocused, generation: panel.focusRequestGeneration)
        return view
    }

    func updateNSView(_ view: ChiefPanelHostView, context: Context) {
        view.show(panel.conversationID)
        view.updatePresentation(visible: isVisibleInUI, focused: isFocused, generation: panel.focusRequestGeneration)
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
    private var pendingFocus = false
    private var canTakeFocus = false
    private var isPresented = false
    private var stopped = false
    /// A new conversation was started from this tab's settings panel.
    var onOpenConversation: (ConversationID) -> Void = { _ in }

    init(conversation: ConversationID?) {
        self.focusGeneration = -1
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

    /// Visibility drives read receipts; focus requests survive the initial mount.
    func updatePresentation(visible: Bool, focused: Bool, generation: Int) {
        isPresented = visible
        canTakeFocus = visible && focused
        transcript?.isActive = visible
        if generation != focusGeneration {
            focusGeneration = generation
            pendingFocus = generation > 0
        }
        if canTakeFocus && pendingFocus { focusComposer() }
    }

    /// Puts the keyboard in the message box once this pane has joined its window.
    func focusComposer() {
        guard window != nil else { pendingFocus = true; return }
        pendingFocus = false
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
        view.isActive = isPresented
        // A new conversation opens a native workspace through the host action.
        view.onOpenConversation = { [weak self] id in self?.onOpenConversation(id) }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        transcript = view
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pane appeared: a pending focus request lands now.
        if window != nil, (canTakeFocus && pendingFocus) || window?.firstResponder === self { focusComposer() }
    }
}
