import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// In a small window the chat keeps its newest message in view: each send and each reply lands
/// on screen while the reader is at the bottom, as in a large window (first-run audit row 8,
/// cmux-shots/first-run at 4:49: in a shrunk window every "hello?" and the Chief's reply stayed
/// below the field, and the composer only cleared). A reader who scrolled up stays where they are.
///
/// Home draws the chat at 1.5 times its size (the app's default zoom), so a 320 x 400 pt pane
/// lays the transcript out in about 213 x 267 pt: less than the field, the header and one wrapped
/// reply. Each case opens the real view over a real `HomeStore` the way the window got small:
/// opened small (a relaunch restores the small window), shrunk on screen, or shrunk while another
/// workspace hid Home.
@MainActor @Suite(.serialized) struct HomeSmallWindowFollowTests {
    enum Path: String, CaseIterable, CustomTestStringConvertible {
        case openedSmall, shrunk, shrunkWhileHidden
        var testDescription: String { rawValue }
    }

    static let large = NSSize(width: 900, height: 700)
    static let small = NSSize(width: 320, height: 400)
    /// The Chief's first-run refusal, the reply of the audit's video: long enough to wrap to many lines.
    static let reply = HomeChatRig.tag + "(turn refused: the Chief runs Claude only through its own Claude Code adapter, "
        + "and claude asks for one running claude; there is none. Fix the harness, check that the configured "
        + "route answers its version probe, and send the message again.)"

    private func place(_ rig: HomeChatRig, _ size: NSSize) {
        rig.view.frame = NSRect(origin: .zero, size: size)
        rig.window.setContentSize(size)
        rig.frame()
    }

    private func open(_ path: Path) async throws -> HomeChatRig {
        let start = path == .openedSmall ? Self.small : Self.large
        let rig = try await HomeChatRig(history: 6, width: start.width, height: start.height)
        rig.view.zoom = 1.5
        rig.frame()
        switch path {
        case .openedSmall:
            break
        case .shrunk:
            place(rig, Self.small)
        case .shrunkWhileHidden:
            // Another workspace's tab covers Home: its view leaves the window, the window shrinks,
            // then Home is shown again at the new size.
            let view = rig.view
            rig.window.contentView = NSView(frame: NSRect(origin: .zero, size: Self.large))
            rig.window.setContentSize(Self.small)
            view.frame = NSRect(origin: .zero, size: Self.small)
            rig.window.contentView = view
            rig.frame()
        }
        for _ in 0..<3 { rig.frame() }
        return rig
    }

    /// The newest row shows: pinned, at the bottom, and the row's bottom between the header and the field.
    private func expectNewestShows(_ rig: HomeChatRig, _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let demo = try #require(rig.view.controller.demo, sourceLocation: sourceLocation)
        let state = demo.store.state
        #expect(state.ui.scroll.pinnedToBottom, "\(comment): not pinned to the newest message", sourceLocation: sourceLocation)
        let y = demo.collection.contentOffset.y
        #expect(abs(y - demo.pinnedOffset) < 1, "\(comment): offset \(y), bottom \(demo.pinnedOffset)", sourceLocation: sourceLocation)
        let last = demo.model.count - 1
        #expect(last >= 0, "\(comment): no rows", sourceLocation: sourceLocation)
        guard last >= 0 else { return }
        // The row's own bottom: `layout.frame(for:)` pads a cell by `RowDraw.margin` on each side.
        let bottom = demo.windowY(contentY: demo.layout.contentTop(last) + (demo.model.rows[checked: last]?.spec.height ?? 0))
        #expect(bottom <= demo.anchorY + 1 && bottom > demo.visibleTop,
                "\(comment): the newest row ends at \(bottom) pt; the field starts at \(demo.anchorY) pt, the header ends at \(demo.visibleTop) pt",
                sourceLocation: sourceLocation)
    }

    @Test(arguments: Path.allCases)
    func sendsAndRepliesStayInViewInASmallWindow(path: Path) async throws {
        let rig = try await open(path)
        defer { rig.stop() }
        try expectNewestShows(rig, "\(path) before any send")
        for round in 0..<3 {
            await rig.send(HomeChatRig.tag + "hello? \(round)")
            for _ in 0..<3 { rig.frame() }
            try expectNewestShows(rig, "\(path), send \(round)")
            #expect(await rig.post(Self.reply + " \(round)", key: IdempotencyKey("refusal-\(round)")))
            for _ in 0..<3 { rig.frame() }
            try expectNewestShows(rig, "\(path), reply \(round)")
        }
    }

    /// A shrink is not the reader scrolling: the chat stays pinned through each step of it.
    @Test func aShrinkKeepsThePinThroughEachStep() async throws {
        let rig = try await HomeChatRig(history: 6, width: Self.large.width, height: Self.large.height)
        defer { rig.stop() }
        rig.view.zoom = 1.5
        for _ in 0..<3 { rig.frame() }
        let demo = try #require(rig.view.controller.demo)
        var log: [String] = []
        func note(_ step: String) {
            let s = demo.store.state.ui.scroll
            log.append("\(step): pinned \(s.pinnedToBottom) back \(s.offset) offset \(demo.collection.contentOffset.y) bottom \(demo.pinnedOffset)")
        }
        note("large")
        #expect(demo.store.state.ui.scroll.pinnedToBottom, "pinned before the shrink")
        rig.view.frame = NSRect(origin: .zero, size: Self.small)
        note("view frame")
        rig.window.setContentSize(Self.small)
        note("window size")
        rig.window.contentView?.layoutSubtreeIfNeeded()
        note("layout")
        rig.frame()
        note("frame")
        #expect(demo.store.state.ui.scroll.pinnedToBottom, "the shrink unpinned the chat: \(log.joined(separator: "; "))")
    }

    /// The control: a reader who scrolled up keeps their place when a reply arrives below.
    @Test func aReaderWhoScrolledUpKeepsTheirPlace() async throws {
        let rig = try await HomeChatRig(history: 40, width: Self.small.width, height: Self.small.height)
        defer { rig.stop() }
        rig.view.zoom = 1.5
        for _ in 0..<3 { rig.frame() }
        let demo = try #require(rig.view.controller.demo)
        let up = max(demo.minOffset, demo.pinnedOffset - 400)
        demo.setOffset(up)
        demo.userScrolled()
        rig.frame()
        #expect(!demo.store.state.ui.scroll.pinnedToBottom, "scrolled up")
        // The reader's place: the first visible row's top in the window (content coordinates rebase).
        let key = try #require(demo.firstVisibleKey)
        let place = { () -> CGFloat? in demo.model.index[key].map { demo.windowY(contentY: demo.layout.contentTop($0)) } }
        let before = try #require(place())
        #expect(await rig.post(Self.reply, key: IdempotencyKey("refusal-up")))
        for _ in 0..<3 { rig.frame() }
        #expect(!demo.store.state.ui.scroll.pinnedToBottom, "a reply does not pull a reader who scrolled up")
        let after = try #require(place())
        #expect(abs(after - before) < 1, "the reader's row \(key) moved from \(before) to \(after) pt")
    }
}
