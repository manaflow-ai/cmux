import CmuxNextDesign
import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A cmux page draws no background of its own in WebKit (`drawsBackground` off), so the pane, the
/// window's vibrancy or Liquid Glass and the background opacity show through it. In Chromium the
/// page host asks for the same: the page is see-through before its first document paints.
@MainActor
struct PageChromiumSeeThroughTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.see-through", resource: "see-through", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-see-through-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aChromiumPageIsSeeThroughBeforeItsFirstDocument() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting,
                                                   lowPowerMode: LowPowerMode(enabled: false)))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.showsChromium)
        #expect(page.seeThrough == true)
        // Set before the document loads, so not even its first frame paints an opaque page color.
        #expect(page.seeThroughAtFirstLoad == .some(true))
        view.close()
    }
}
