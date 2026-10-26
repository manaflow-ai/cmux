import AppKit
@testable import CmuxNextApp
@testable import CmuxNextPages
import Foundation
import Testing

/// A page discarded in place (p13-webui-030) shows its hide-time snapshot in the key's turn: the pane
/// that switches to it holds no paint (the snapshot is its first frame), so the page is visible at
/// once and the tab it leaves goes in the same swap. Runs a real pane in a window.
@MainActor @Suite(.serialized) struct PageDiscardSnapshotPaneTests {
    @Test func aDiscardedPageWithASnapshotShowsAtOnceWithNoPaintHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discard-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.discard-pane", resource: "discard-pane", processGroup: .solo, namespaces: [])
        let page = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        defer { page.close() }
        let tab = InternalPageView(key: "k", page: InternalPageID(rawValue: "cmux.markdown"), content: page)
        let pane = TabSwitchNoBlankFrameTests.Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)

        // Hidden (in no window), with the snapshot its hide kept, then discarded.
        page.keepForDiscard(snapshot: try Self.image(), state: nil)
        #expect(page.discardPage())
        #expect(!page.hasPainted)
        #expect(!tab.awaitsFirstPaint, "a discarded page with a snapshot waits for a paint")

        // The show: the lifecycle's thaw runs first in the key's turn, then the pane swaps.
        page.restoreDiscardedPage()
        pane.select(tab)
        #expect(page.showsDiscardSnapshot)
        #expect(tab.alphaValue == 1, "the pane held the discarded page invisible behind the last tab")
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(tab)], "the last tab stayed over the snapshot")
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return try #require(context.makeImage())
    }
}
