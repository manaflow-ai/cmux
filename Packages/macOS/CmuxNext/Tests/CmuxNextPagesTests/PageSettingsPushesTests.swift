import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
@testable import CmuxNextWakeups
import Foundation
import Testing

/// A page follows the UI scale and the status look through service observations on its host's scheduler
/// (``PageSettingsPushes``): a change reaches the page as one posted visible task, never in the
/// setting's own turn, and it reaches a hidden page too, so the page's first frame after a show is at the new scale.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageSettingsPushesTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.settings-pushes", resource: "settings-pushes", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-pushes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aUIScaleChangeReachesAHiddenPageInOnePostedTask() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = LifecycleDeadlineRig()
        let hosting = FakeChromiumHosting()
        let host = WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: rig.scheduler)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        defer { host.close(view) }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        view.isHidden = true
        #expect(view.window == nil && view.isHidden, "the page is not hidden")

        let design = DesignSettings.shared
        let before = design.uiScale
        defer { design.uiScale = before }
        design.uiScale = before + 0.25
        #expect(page.zoom != view.pageZoom, "the scale reached the page in the setting's own turn")

        // One frame runs the posted push (the time never moves, so the Chromium fallback stays armed).
        rig.fire(movingTime: false)
        #expect(page.zoom == view.pageZoom, "the hidden page never got the new scale")
        #expect(view.chromiumSession != nil, "the page fell back to WebKit")
    }
}
