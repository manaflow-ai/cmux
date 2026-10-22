import AppKit
@testable import CmuxNextPages
import Foundation
import Testing

/// A Chromium page draws in a window over the host's, so a pane's tab strip over a chat that shares
/// its row was covered: the chat's header tools showed on the right and the tabs were gone (dogfood,
/// 2026-10-21, a chat docked by a Cmd-clicked link). The page view leaves the native UI's rects out
/// of its Chromium page, set before or after the page attaches.
@MainActor
struct PageChromiumNativeHolesTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-holes", resource: "chromium-holes", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chromium-holes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func start(_ hosting: FakeChromiumHosting, holes: [CGRect]) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.chromiumClock = PageTestClock.never
        view.nativeHoles = holes
        let starting = try #require(view.chromiumStart)
        await starting.value
        return (view, try #require(hosting.made.first))
    }

    @Test func holesSetBeforeChromiumAttachesReachThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let strip = CGRect(x: 0, y: 0, width: 420, height: 36), toolbar = CGRect(x: 767, y: 0, width: 33, height: 36)
        let (view, page) = try await start(FakeChromiumHosting(), holes: [strip, toolbar])
        defer { view.close() }
        let shown = try #require(page.holes.last)
        #expect(shown.map { view.convert($0, from: page.contentView) } == [strip, toolbar],
                "the Chromium page covers the pane's strip: \(page.holes)")
    }

    @Test func holesFollowTheRowAndEndWithIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await start(FakeChromiumHosting(), holes: [])
        defer { view.close() }
        let narrower = CGRect(x: 0, y: 0, width: 300, height: 36)
        view.nativeHoles = [narrower]
        #expect(page.holes.last.map { $0.map { view.convert($0, from: page.contentView) } } == [narrower])
        view.nativeHoles = []
        #expect(page.holes.last == [], "a chat that left the row still has a hole over its header: \(page.holes)")
    }
}
