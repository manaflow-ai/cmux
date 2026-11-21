#if DEBUG
import CmuxNextDesign
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp

/// Follow-up F1 of #39460: a capture step fails only on an answer with `error` (or `ok: false`), and
/// `debug.page`'s `drag` answered `{dragged: false}` when the drag never reached the page (a WebKit
/// page has no DevTools drag), so the table split edge scene could pass with the edge unmoved. An input
/// that did not happen answers an error, as `scroll` already does.
@MainActor
struct DebugPageFailedInputTests {
    @Test func aDragThatCannotReachThePageAnswersAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Drag</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.debug-page-drag", resource: "debug-page-drag", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/"))
        defer { view.close() }
        let answer = await DebugPages.handle(["page": .string(descriptor.id), "action": .string("drag"), "x1": .number(10), "y1": .number(10), "x2": .number(200), "y2": .number(10)],
                                             services: nil)
        guard case .object(let members) = answer else { Issue.record("not an object: \(answer)"); return }
        #expect(members["error"] != nil)
        #expect(members["dragged"] == nil)
    }
}
#endif
