#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Review of #27664 (the collection-view transcript): a disclosure opened or closed in a row must
/// draw at its new height, hold the tapped line where it is drawn (native lines too), and a text
/// size change must move every row to the cell type it is drawn by at that size. Each check runs
/// the real transcript controller in a window and reads the rows' drawn frames frame by frame.
@MainActor
@Suite(.serialized) struct NativeRowFoldTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// Turns of a prompt, one read tool call with twelve lines of output (a native line at rest at
    /// a standard text size, its output a SwiftUI code card when open) and a short answer.
    static func events(turns: Int) -> [AgentSessionEvent] {
        (0 ..< turns).flatMap { n -> [AgentSessionEvent] in
            [
                .userMessage(text: "prompt \(n)", promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at),
                .turnStarted(turnId: "t\(n)", at: at),
                .update(.toolCall(ACPToolCall(id: "c\(n)", title: "Read a\(n).swift", kind: .read, status: .completed,
                                              content: [.content(.text((0 ..< 12).map { "let line\($0) = \(n)" }.joined(separator: "\n")))],
                                              locations: [.init(path: "Sources/a\(n).swift")]))),
                .update(.agentMessageChunk(text: "Answer \(n): the dialer retries with backoff.", messageId: "m\(n)")),
                .turnResult(turnId: "t\(n)", status: .completed, errorText: nil, at: at),
            ]
        }
    }

    @MainActor
    struct Chat {
        let controller: ChatTranscriptController
        let surface: AgentChatSurface
        let scroll: UICollectionView
        let window: UIWindow
        var list: ChatTranscriptList { controller.transcriptList }

        /// Row `id`'s cell top in the scroll view's own frame (where it is drawn on screen), and
        /// its height, from the layers as drawn.
        func line(_ id: String) -> (y: CGFloat, height: CGFloat)? {
            guard let cell = list.cell(for: id) else { return nil }
            let frame = cell.layer.presentation()?.frame ?? cell.frame
            let offset = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            return (frame.minY - offset, frame.height)
        }

        /// About one display frame: the main queue and the run loop both turn (the list's
        /// reloads are main-queue tasks), then the layout is committed.
        func frame() async {
            try? await Task.sleep(for: .milliseconds(16))
            controller.view.layoutIfNeeded()
            CATransaction.flush()
        }

        func frames(_ count: Int) async {
            for _ in 0 ..< count { await frame() }
        }

        /// The tool rows whose cells are wholly on screen, top first, with their call ids.
        func toolRows() -> [(id: String, call: String)] {
            let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let bottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
            return list.visibleRowIDs.compactMap { id in
                guard case .tool(let call) = list.row(id)?.kind, let cell = list.cell(for: id),
                      cell.frame.minY >= top, cell.frame.maxY <= bottom else { return nil }
                return (id, call.id)
            }
        }

        /// What draws the rows on screen: native cells and SwiftUI cells.
        func cellKinds() -> (native: Int, hosted: Int) {
            let cells = list.visibleRowIDs.compactMap { list.cell(for: $0) }
            return (cells.filter { $0 is ChatNativeRowCell }.count, cells.filter { $0 is ChatRowCell }.count)
        }
    }

    func chat(category: UIContentSizeCategory? = nil) async throws -> Chat {
        let store = AgentChatStore(source: Silent())
        store.nextFrame = nil
        store.apply(.batch(Self.events(turns: 30)))
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        if let category { window.traitOverrides.preferredContentSizeCategory = category }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        let chat = Chat(controller: controller, surface: surface, scroll: scroll, window: window)
        for _ in 0 ..< 150 where scroll.contentSize.height < scroll.bounds.height * 4 { await chat.frame() }
        try #require(scroll.contentSize.height >= scroll.bounds.height * 4, "content measured \(scroll.contentSize.height)")
        // Rows near the reader are laid out and measured on later frames.
        await chat.frames(20)
        return chat
    }

    /// Blocker 1: a row's measured height was reused while its revision matched, and a
    /// disclosure is not part of a row's revision: a tool row opened at an accessibility text
    /// size (every row a SwiftUI cell there) kept its closed height, its output clipped under
    /// the rows below. Opened, closed and opened again, it takes each state's height.
    @Test func aReopenedRowTakesItsOpenHeight() async throws {
        let chat = try await chat(category: .accessibilityLarge)
        defer { chat.window.isHidden = true }
        let row = try #require(chat.toolRows().first, "a tool row on screen")
        #expect(chat.list.cell(for: row.id) is ChatRowCell, "a SwiftUI row at an accessibility size")
        let closed = try #require(chat.line(row.id)).height
        let key = "tool-\(row.call)"

        chat.surface.disclosures.set(key, true)
        await chat.frames(30)
        let opened = try #require(chat.line(row.id)).height
        #expect(opened > closed + 60, "the output shows: \(closed) -> \(opened)")

        chat.surface.disclosures.set(key, false)
        await chat.frames(30)
        let closedAgain = try #require(chat.line(row.id)).height
        #expect(abs(closedAgain - closed) <= 1, "back to its line: \(closedAgain), was \(closed)")

        chat.surface.disclosures.set(key, true)
        await chat.frames(30)
        let reopened = try #require(chat.line(row.id)).height
        #expect(abs(reopened - opened) <= 1, "reopened at its open height: \(reopened), open was \(opened)")
    }

    /// CI at f8ed786e (`aReopenedRowTakesItsOpenHeight` failing in the full suite): a row's
    /// height was recorded for a disclosure state its cell did not draw yet. The list installs the
    /// new state's layout before it reconfigures the cell, and the layout pass in between measured
    /// the cell still drawing the old state, then kept that height for the new one (and handed it
    /// to the cell as its known height). When the reload and its layout pass run before SwiftUI
    /// has updated the row (a busy main queue), the height kept for the state is still the one
    /// measured when the row last settled in it.
    @Test func aRowsHeightForAStateIsTheOneItSettledAt() async throws {
        let chat = try await chat(category: .accessibilityLarge)
        defer { chat.window.isHidden = true }
        let row = try #require(chat.toolRows().first, "a tool row on screen")
        let key = "tool-\(row.call)"
        let disclosures = chat.surface.disclosures
        let closed = try #require(chat.line(row.id)).height
        disclosures.set(key, true)
        await chat.frames(30)
        let opened = try #require(chat.line(row.id)).height
        try #require(opened > closed + 60, "the output shows: \(closed) -> \(opened)")
        disclosures.set(key, false)
        await chat.frames(30)
        try #require(abs((chat.line(row.id)?.height ?? 0) - closed) <= 1)

        // Opened again, with the list's reload and its layout pass before SwiftUI updates the row.
        disclosures.set(key, true)
        chat.list.reloadIfDisclosuresChanged()
        chat.list.collectionView.layoutIfNeeded()
        let kept = chat.list.layout.knownHeight(of: row.id)?.height
        #expect(kept.map { abs($0 - opened) <= 1 } ?? true, "the open state's height is the one it settled at: \(String(describing: kept)), open was \(opened)")
        await chat.frames(30)
        let reopened = try #require(chat.line(row.id)).height
        #expect(abs(reopened - opened) <= 1, "reopened at its open height: \(reopened), open was \(opened)")

        // And closed the same way.
        disclosures.set(key, false)
        chat.list.reloadIfDisclosuresChanged()
        chat.list.collectionView.layoutIfNeeded()
        let keptClosed = chat.list.layout.knownHeight(of: row.id)?.height
        #expect(keptClosed.map { abs($0 - closed) <= 1 } ?? true, "the closed state's height is the one it settled at: \(String(describing: keptClosed)), closed was \(closed)")
        await chat.frames(30)
        #expect(abs((chat.line(row.id)?.height ?? 0) - closed) <= 1)
    }

    /// CI at f8ed786e (`aReopenedRowTakesItsOpenHeight` failing in the full suite, closed again
    /// 94 pt for a 32 pt line): the root cause. A SwiftUI row's cell that sits under the top safe
    /// area (the status bar; the transcript also reports its header there) passed that inset to
    /// its hosted view, which padded itself by it, and the row was measured and kept 62 pt
    /// taller. In that test the close re-pinned the row above the screen's top when it was
    /// measured, so whether it failed depended on where the row was at that moment. A row
    /// measured under the safe area takes its own height.
    @Test func aRowMeasuredUnderTheTopSafeAreaTakesItsOwnHeight() async throws {
        let chat = try await chat(category: .accessibilityLarge)
        defer { chat.window.isHidden = true }
        let row = try #require(chat.toolRows().first, "a tool row on screen")
        let height = try #require(chat.line(row.id)).height
        let top = try #require(chat.list.cell(for: row.id)).frame.minY
        chat.surface.following = false
        // The row's top 10 pt below the scroll view's top, under the 62 pt status bar.
        chat.scroll.contentOffset.y = top - 10
        chat.list.collectionView.layoutIfNeeded()
        let cell = try #require(chat.list.cell(for: row.id) as? ChatRowCell)
        let y = cell.frame.minY - chat.scroll.contentOffset.y
        try #require(y < chat.window.safeAreaInsets.top, "the row sits under the safe area: y \(y), inset \(chat.window.safeAreaInsets.top)")
        let indexPath = try #require(chat.list.collectionView.indexPath(for: cell))
        let attributes = try #require(chat.list.layout.layoutAttributesForItem(at: indexPath))
        cell.known = nil
        let fitted = cell.preferredLayoutAttributesFitting(attributes)
        #expect(abs(fitted.size.height - height) <= 1, "measured under the safe area: \(fitted.size.height), its height \(height)")
    }

    /// Blocker 2: a native line's tap opened its disclosure without the transcript's hold, so a
    /// chat following its newest row re-pinned to the bottom and the tapped line jumped up by
    /// the body's height (base's "disclosures hold their line", a5efcb96 and 5d53628b). Tapped
    /// on its native line and closed with its SwiftUI row's button, the line stays within 1 pt
    /// of where it was drawn on every frame, and the chat follows its newest row again after.
    @Test func aNativeLineHoldsItsPlaceWhileTheChatFollowsItsNewestRow() async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        #expect(chat.surface.following)
        let row = try #require(chat.toolRows().last, "a tool row on screen")
        let native = try #require(chat.list.cell(for: row.id) as? ChatNativeRowCell, "a native line at rest")
        let before = try #require(chat.line(row.id))
        let key = "tool-\(row.call)"

        native.perform(.toggle(key))
        // Every frame until the hold lets go (its animation completes; a loaded simulator's frames
        // come late), and at least 60.
        var opening: [CGFloat] = []
        for frame in 0 ..< 240 where frame < 60 || chat.controller.isHoldingFold {
            await chat.frame()
            if let line = chat.line(row.id) { opening.append(line.y) }
        }
        let opened = try #require(chat.line(row.id))
        #expect(chat.list.cell(for: row.id) is ChatRowCell, "the open row is its SwiftUI view")
        #expect(opened.height > before.height + 100, "the output shows: \(before.height) -> \(opened.height)")
        #expect(!opening.isEmpty && opening.allSatisfy { abs($0 - before.y) <= 1 },
                "the line moved while opening: from \(before.y) through \(opening)")
        #expect(!chat.controller.isHoldingFold, "the hold lets go")
        #expect(!chat.surface.following, "the open pushed the newest row down: the view stays")

        // Closed as the SwiftUI row's own button does (`ToolRowView`).
        let disclosures = chat.surface.disclosures
        toggleDisclosure(chat.list.context.foldHold) { disclosures.set(key, false) }
        var closing: [CGFloat] = []
        for frame in 0 ..< 240 where frame < 60 || chat.controller.isHoldingFold {
            await chat.frame()
            if let line = chat.line(row.id) { closing.append(line.y) }
        }
        #expect(!chat.controller.isHoldingFold, "the hold lets go")
        let closed = try #require(chat.line(row.id))
        #expect(abs(closed.height - before.height) <= 1, "back to its line: \(closed.height), was \(before.height)")
        #expect(!closing.isEmpty && closing.allSatisfy { abs($0 - before.y) <= 1 },
                "the line moved while closing: from \(before.y) through \(closing)")
        #expect(chat.surface.following, "back on the newest row, the chat follows it again")
    }

    /// Review of 2a38f796 (optional): a held line waits for the list to show its disclosure
    /// change before it lets go, but the reader's own scroll (a drag, Jump to latest, Find) is
    /// their intent and releases the hold at once.
    @Test func theReadersOwnScrollReleasesAHeldLineAtOnce() async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        let row = try #require(chat.toolRows().last, "a tool row on screen")
        chat.list.context.foldHold.begin()
        // The list reloads for this on a later turn of the main queue: the change is pending.
        chat.surface.disclosures.set("tool-\(row.call)", true)
        #expect(chat.controller.isHoldingFold)
        chat.controller.scrollTranscript(toTop: false, animated: false)
        #expect(!chat.controller.isHoldingFold, "the reader's scroll lets go at once")
    }

    /// Edge P1: a switch to an accessibility text size installed the new environment before
    /// choosing the rows to reload, so no row counted as native any more and the native cells on
    /// screen stayed native. Every row on screen is a SwiftUI cell at that size, and native
    /// rows come back at a standard size.
    @Test func aTextSizeSwitchMovesRowsBetweenNativeAndSwiftUI() async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        #expect(chat.cellKinds().native > 0, "native rows at a standard size: \(chat.cellKinds())")

        chat.window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        await chat.frames(30)
        let large = chat.cellKinds()
        #expect(large.native == 0 && large.hosted > 0, "every row is SwiftUI at an accessibility size: \(large)")

        chat.window.traitOverrides.preferredContentSizeCategory = .large
        await chat.frames(30)
        #expect(chat.cellKinds().native > 0, "native rows again at a standard size: \(chat.cellKinds())")
    }
}
#endif
