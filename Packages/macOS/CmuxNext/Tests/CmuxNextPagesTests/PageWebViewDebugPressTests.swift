#if DEBUG
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// `debug.agent_pane click` on a chat shown in Chromium: a trusted DevTools press and release at
/// the element's center in CSS pixels, as a person's click, in a window that never activates (a
/// capture slot), where no AppKit click reaches the Chromium page.
@MainActor
struct PageWebViewDebugPressTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.press-page", resource: "press-page", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-press-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func pressSendsADevToolsPressAndReleaseAtThePoint() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting, deadlines: .testing()))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(await view.debugPress(x: 308, y: 18) == .devtools)
        let presses = page.calls.filter { $0.method == "Input.dispatchMouseEvent" }
        #expect(presses.map { $0.params["type"] as? String } == ["mousePressed", "mouseReleased"])
        for press in presses {
            #expect(press.params["x"] as? Double == 308)
            #expect(press.params["y"] as? Double == 18)
            #expect(press.params["button"] as? String == "left")
            #expect(press.params["clickCount"] as? Int == 1)
        }
        view.close()
    }

    /// A WebKit page has no DevTools input: the caller clicks it with AppKit events.
    @Test func aWebKitPageIsNotPressed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil, deadlines: .testing()))
        #expect(await view.debugPress(x: 1, y: 1) == nil)
        view.close()
    }
}
#endif
