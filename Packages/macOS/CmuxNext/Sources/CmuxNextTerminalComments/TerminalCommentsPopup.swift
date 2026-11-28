public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextDiff
import Observation
import SwiftUI

/// A terminal's comment threads (diff-comments-threads-v1): a popup card at the terminal's top trailing
/// corner listing each thread's quote, comment, "Sent" and then the agent's reply, with Resolve, and
/// Show in Terminal for a thread that kept its scrollback rows (it scrolls back to them).
/// It opens after Comment… sends, and again by itself when a reply comes while it is closed
/// (``TerminalCommentThreads``).
@MainActor
final class TerminalCommentsPopup {
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.terminal.comments"))
    private let state = TerminalCommentsPopupState()
    private var content: FirstMouseHostingView<TerminalCommentsPopupView>?
    private weak var anchor: NSView?
    /// Resizes the card while it shows and a thread changes (the reply came, one resolved).
    private var following: Task<Void, Never>?

    init() {
        popup.onDismiss = { [weak self] in self?.closed() }
    }

    var isShown: Bool { popup.isShown }

    /// Shows the threads of `model` on terminal `terminalID` over the terminal view `anchor`.
    func show(_ model: CommentThreadsModel, terminalID: String, anchor: NSView, makeKey: Bool,
              reveal: @escaping @MainActor (CommentThread) -> Void) {
        guard let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else { return }
        self.anchor = anchor
        state.model = model
        state.terminalID = terminalID
        state.onReveal = reveal
        state.colors = anchor.performWithTheme { PopupCardColors.resolve() }
        state.onResolve = { [weak self, weak model] id in
            guard let model else { return }
            // task-owner: one resolve (a delete on the session host); ends when it does.
            Task { [weak self] in
                await model.resolve(id)
                if model.threads(onTerminal: terminalID).isEmpty { self?.close() }
            }
        }
        let content = content ?? makeContent()
        popup.panel.adoptThemeScope(of: anchor)
        place(content, anchor: anchor, window: window, makeKey: makeKey)
        follow(model, terminalID: terminalID)
    }

    func close() {
        popup.hide()
        closed()
    }

    private func place(_ content: NSView, anchor: NSView, window: NSWindow, makeKey: Bool) {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // A strip along the terminal's top edge: the card hangs under it at the trailing corner.
        let bounds = anchor.bounds
        let strip = NSRect(x: bounds.minX, y: anchor.isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1)
        let rect = window.convertToScreen(anchor.convert(strip, to: nil))
        popup.show(size: CGSize(width: ceil(size.width), height: ceil(size.height)), anchor: rect, in: window,
                   preferred: .below, trailing: true, makeKey: makeKey)
    }

    private func makeContent() -> FirstMouseHostingView<TerminalCommentsPopupView> {
        let content = FirstMouseHostingView<TerminalCommentsPopupView>(rootView: TerminalCommentsPopupView(state: state))
        let card = Glass.makeMenuPanel(content: content)
        popup.panel.adoptPopupStyle(card: card)
        self.content = content
        return content
    }

    private func follow(_ model: CommentThreadsModel, terminalID: String) {
        following?.cancel()
        // task-owner: the card's resize on a thread change; cancelled when the card closes.
        following = Task { [weak self] in
            for await _ in ObservationStream({ model.threads(onTerminal: terminalID) }) { self?.resize() }
        }
    }

    private func resize() {
        guard popup.isShown, let content else { return }
        guard let anchor, let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else { return close() }
        place(content, anchor: anchor, window: window, makeKey: popup.panel.isKeyWindow)
    }

    private func closed() {
        following?.cancel()
        following = nil
        anchor = nil
    }
}

/// What the card's SwiftUI rows read.
@MainActor
@Observable
final class TerminalCommentsPopupState {
    var model: CommentThreadsModel?
    var terminalID = ""
    var colors = PopupCardColors()
    @ObservationIgnored var onResolve: (String) -> Void = { _ in }
    @ObservationIgnored var onReveal: (CommentThread) -> Void = { _ in }

    var threads: [CommentThread] { model?.threads(onTerminal: terminalID) ?? [] }
}

struct TerminalCommentsPopupView: View {
    let state: TerminalCommentsPopupState

    var body: some View {
        let colors = state.colors
        VStack(alignment: .leading, spacing: 10) {
            Text(TerminalCommentStrings.header)
                .font(Font(Typography.header))
                .foregroundStyle(colors.secondary)
            ForEach(state.threads) { thread in
                TerminalCommentThreadRow(thread: thread, colors: colors, reveal: { state.onReveal(thread) }) { state.onResolve(thread.id) }
                if thread.id != state.threads.last?.id {
                    Rectangle().fill(colors.separator).frame(height: 1)
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .accessibilityIdentifier("terminal.comments.popup")
    }
}

/// One thread: the quote, the comment, "Sent", then the reply (or that it is awaited or failed).
private struct TerminalCommentThreadRow: View {
    let thread: CommentThread
    let colors: PopupCardColors
    let reveal: () -> Void
    let resolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.quote)
                .font(Font(Typography.system(.monospaced, size: Typography.caption.pointSize)))
                .foregroundStyle(colors.secondary)
                .lineLimit(4)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(colors.separator).frame(width: 2) }
            Text(thread.message)
                .font(Font(Typography.body))
                .foregroundStyle(colors.primary)
                .fixedSize(horizontal: false, vertical: true)
            if thread.state != .draft {
                Text(TerminalCommentStrings.sent)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
            }
            switch thread.state {
            case .sent:
                Text(TerminalCommentStrings.waiting)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
            case .answered:
                Text(thread.reply ?? "")
                    .font(Font(Typography.body))
                    .foregroundStyle(colors.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terminal.comments.reply")
            case .draft:
                EmptyView()
            }
            HStack {
                Spacer()
                if thread.terminalRows != nil {
                    Button(TerminalCommentStrings.show, action: reveal)
                        .controlSize(.small)
                        .accessibilityIdentifier("terminal.comments.show")
                }
                Button(TerminalCommentStrings.resolve, action: resolve)
                    .controlSize(.small)
            }
        }
    }
}
