import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A closed page leaves the view tree in the close's turn and its engine page ends after it
/// (p13-webui-064): Cmd-W on a page tab makes 0 engine close calls in its turn.
@MainActor
struct PageRetirerTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-retirer", resource: "page-retirer", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-retirer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeHost(_ hosting: FakeChromiumHosting) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never)
    }

    @Test func theHostsCloseDetachesThePageAndMakesNoEngineCloseInItsTurn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let pane = NSView()
        pane.addSubview(view)
        host.close(view)
        #expect(view.superview == nil, "the closed page stayed in its pane")
        #expect(!page.closed, "the close's turn closed the engine page")
        #expect(host.openPages.isEmpty)
        #expect(host.registry.pages().isEmpty)
    }
}
