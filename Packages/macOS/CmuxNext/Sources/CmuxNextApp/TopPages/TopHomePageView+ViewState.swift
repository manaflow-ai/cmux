import AppKit
import CmuxHomeCore
import CmuxNextHome

// MARK: View state (`memoryDiscardInternalPages`)

extension TopHomePageView {
    /// What this page shows that Home's store does not keep: the shown conversation and its open
    /// thread, the list's search and scroll, and the New Message page (each conversation's draft
    /// and transcript scroll stay in the store). A Home tab or dock whose view was discarded gives
    /// it to its next view.
    struct ViewState: Equatable {
        var shown: ConversationID?
        /// The message whose thread branch the transcript has open.
        var thread: String?
        /// The list's search text.
        var search = ""
        /// Where the list was scrolled to.
        var listScroll: CGPoint?
        /// The New Message page's draft, nil when there is none or it is empty.
        var newMessage: HomeNewMessageView.Saved?
        /// The New Message page is the one on screen.
        var composing = false
    }

    var viewState: ViewState {
        ViewState(shown: shown, thread: host.flatMap { HomePageTab.transcript(in: $0) }?.openThreadMessage, search: list.searchText,
                  listScroll: list.scrollOrigin, newMessage: newMessage.flatMap { $0.isEmpty ? nil : $0.saved },
                  composing: isComposingNewMessage)
    }

    /// Shows `state` on this new page: its conversation and thread, the list's search and
    /// scroll, and a kept New Message draft with its row, on screen when it was. Showing a tab
    /// again is not the person choosing it: the keyboard moves only when nothing holds it, as
    /// `show(_:)` does.
    func restore(_ state: ViewState) {
        let keyboardFree = window?.firstResponder == nil || window?.firstResponder === window
        if !state.search.isEmpty { list.searchText = state.search }
        if let scroll = state.listScroll { restoreListScroll(scroll) }
        if let shown = state.shown { show(HomeDockSelection(conversation: shown.rawValue, message: state.thread)) }
        guard let saved = state.newMessage, let page = keptNewMessage() else { return }
        page.restore(saved)
        if state.composing {
            showNewMessage()
            if keyboardFree { focusPrimaryInput() }
            return
        }
        page.isHidden = true
        list.setDraftRow(HomeNewMessageDraft.rowTitle)
        if let shown { list.select(shown) }
    }

    /// Scrolls the list to `origin` now when it has its rows, else once they first draw.
    private func restoreListScroll(_ origin: CGPoint) {
        guard rows.isEmpty else {
            list.layoutSubtreeIfNeeded()
            list.scrollOrigin = origin
            return
        }
        pendingListScroll = origin
    }
}
