import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." A chat
/// history block's page is as tall as the block and the list scrolls it, so every row is in the page's own viewport.
/// The host streams the part on screen (`cmux.page.visibleSlice`) for the page to draw only those rows: at most once a
/// display frame, nothing when neither the block nor its whole px changed, height 0 off screen, the latest to a page that
/// subscribes again, and the same work per scroll at 100 and 10,000 chats.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarChatsSliceTests {
    @Test func oneSliceAFrameNoneUnchangedZeroOffScreenAndTheLatestOnResubscribe() async throws {
        #expect(PageDescriptor.sidebarChats.admits(PageVisibleSlices.stream))
        let block = try await SidebarChatsBlock(chats: 100)
        defer { block.close() }
        #expect(block.host.provider.routes.contains { $0.prefix == PageVisibleSlices.stream })
        var events: [CmuxNextSettings.JSONValue] = []
        let context = PageCallContext(page: PageDescriptor.sidebarChats.id)
        let surface: CmuxNextSettings.JSONValue = .object(["surface": .string(block.host.surface)])
        let first = try await block.host.provider.slices.subscribe(PageVisibleSlices.stream, filter: surface, context: context) {
            events.append($0)
        }
        block.host.sendSlice()
        events.removeAll()
        _ = block.host.listWork.take()

        // Three scroll events in one frame (30 pt each, whole px): nothing until the frame, then one slice, the last one.
        for _ in 0..<3 { block.scroll(by: 30) }
        #expect(events.isEmpty)
        block.host.sendSlice()
        #expect(events.count == 1)
        #expect(events.last?["top"]?.doubleValue == 90)
        #expect(events.last?["surface"]?.stringValue == "sidebar-chats:earlier")
        #expect(events.last?["height"]?.doubleValue == Double(block.clip.bounds.height))
        #expect(events.last?["revision"]?.intValue == block.host.provider.revision)
        #expect(block.host.listWork.take().rowsConfigured == 1)

        // Unchanged, or moved by under half a px: nothing.
        block.host.sendSlice()
        block.scroll(by: 0.3)
        block.host.sendSlice()
        #expect(events.count == 1)
        #expect(block.host.listWork.take().rowsConfigured == 0)

        // A block push: the same px at the new revision (the page drops a slice older than its block).
        block.rename(2)
        block.host.sendSlice()
        #expect(events.count == 2)
        #expect(events.last?["revision"]?.intValue == block.host.provider.revision)

        // Scrolled past the block: height 0.
        block.scroll(to: block.host.frame.maxY + 50)
        block.host.sendSlice()
        #expect(events.count == 3)
        #expect(events.last?["height"]?.doubleValue == 0)

        // A page that subscribes again (a reload) gets the latest at once.
        first.cancel()
        var again: [CmuxNextSettings.JSONValue] = []
        let second = try await block.host.provider.slices.subscribe(PageVisibleSlices.stream, filter: surface, context: context) {
            again.append($0)
        }
        defer { second.cancel() }
        #expect(again.count == 1)
        #expect(again.first?["height"]?.doubleValue == 0)
        #expect(again.first == events.last)
    }

    @Test func perScrollWorkIsTheSameAt100And10000Chats() async throws {
        var readings: [Int: ListWorkMeter.Reading] = [:]
        for n in VisibleRowsContract.sizes {
            let block = try await SidebarChatsBlock(chats: n)
            defer { block.close() }
            block.host.sendSlice()
            _ = block.host.listWork.take()
            block.scroll(by: block.pitch)
            block.host.sendSlice()
            readings[n] = block.host.listWork.take()
            print("sidebar-chats-slice n=\(n) scroll=\(readings[n].map(\.description) ?? "-")")
        }
        #expect(readings[100] == ListWorkMeter.Reading(rowsConfigured: 1))
        #expect(readings[100] == readings[10_000])
    }

    /// In `VisibleRowsBaseline`: the page draws every chat it is sent until it windows against the slice.
    @Test func visibleRows() async throws {
        try await VisibleRowsContract.check(SidebarChatsRows.self)
    }
}

/// An Earlier block of `chats` chats in a 240 x 400 scrolling list, 200 pt under the list's top, with no page (the
/// page is web: the host's slice is what it would draw).
@MainActor final class SidebarChatsBlock {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    let host = SidebarChatHistoryHost(part: .earlier, makePage: { _ in nil })
    let window: NSWindow
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    var clip: NSClipView { scrollView.contentView }
    var pitch: CGFloat { SidebarLayoutMetrics.standard.rowHeight + SidebarLayoutMetrics.standard.rowSpacing }
    private(set) var chats: [SidebarHistoryChat]

    init(chats count: Int) async throws {
        _ = NSApplication.shared
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        chats = (0..<count).map { SidebarHistoryChat(id: "c\($0)", title: "chat \($0)", updatedAt: start.addingTimeInterval(-Double($0) * 60)) }
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let state = self.state
        let height = state.earlierHeight(.standard)
        let document = Document(frame: NSRect(x: 0, y: 0, width: 240, height: 200 + height + 800))
        scrollView.documentView = document
        host.frame = NSRect(x: 0, y: 200, width: 240, height: height)
        document.addSubview(host)
        host.show(state, metrics: .standard, width: 240)
        host.isHidden = false
        window.orderFrontRegardless()
        scroll(to: 200)
    }

    var state: SidebarChatHistoryState {
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        return SidebarChatHistoryState.make(newest: chats, chat: { byID[$0] }, live: [], pinned: [], limit: chats.count, folded: false)
    }

    /// Rows of the block the list shows now.
    var viewportRows: Int {
        let shown = PageVisibleSliceTracker.visiblePart(of: host).visible
        return shown.isEmpty ? 0 : Int((shown.height / pitch).rounded(.up))
    }

    func scroll(by dy: CGFloat) { scroll(to: clip.bounds.minY + dy) }

    /// Scrolls the list to `y`, as the list's scroll path tells the block (`SidebarChatHistoryViews.followScroll`).
    func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        host.needsSlice()
    }

    /// One chat's title changes; the block is pushed again.
    func rename(_ index: Int) {
        let chat = chats[index]
        chats[index] = SidebarHistoryChat(id: chat.id, title: chat.title + " renamed", updatedAt: chat.updatedAt)
        host.show(state, metrics: .standard, width: 240)
    }

    func close() { window.close() }
}

/// The chat history block for the visible-rows contract. Rows alive are the rows the page draws: today every chat it
/// is sent (the page does not window yet).
@MainActor final class SidebarChatsList: VisibleRowsList {
    let host: SidebarChatHistoryHost
    init(_ host: SidebarChatHistoryHost) { self.host = host }
    var listWork: ListWorkMeter { host.listWork }
    var rowViewsAlive: Int { host.provider.block?.rows.count ?? 0 }
}

@MainActor final class SidebarChatsRows: VisibleRowsFixture {
    static let name = "sidebar chats"
    let block: SidebarChatsBlock
    let list: SidebarChatsList

    init(rows: Int) async throws {
        block = try await SidebarChatsBlock(chats: rows)
        list = SidebarChatsList(block.host)
        block.host.sendSlice()
    }

    var viewportRows: Int { block.viewportRows }

    func changeOneItem() async throws {
        block.rename(2)
        block.host.sendSlice()
    }

    func scrollOneRow() async throws -> Bool {
        block.scroll(by: block.pitch)
        block.host.sendSlice()
        return true
    }

    func resizeOneStep() async throws -> Bool { false }

    func close() { block.close() }
}
