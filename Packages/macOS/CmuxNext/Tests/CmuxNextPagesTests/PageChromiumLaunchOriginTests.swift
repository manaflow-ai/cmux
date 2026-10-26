import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A cmux page in Chromium made while the launch runs follows the launch origin rule (p08-startup-041,
/// feature `chromiumPagesLaunchOrigin`): Home in front asks for its Chromium page in the launch's
/// afterFirstFrame release, before startup completed; a page that does not show asks for none before
/// completion; a page opened after the launch asks at once. Fake engine (``FakeChromiumHosting``) and
/// the shared startup fixture (``StartupTestScheduler``).
@MainActor @Suite(.serialized)
struct PageChromiumLaunchOriginTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.launch-origin", resource: "launch-origin", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-launch-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/home", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        return view
    }

    /// A window ordered in whose visibility node reads `state` (AppKit reports the off-screen test window covered).
    private func window(_ state: Visibility) -> NSWindow {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        _ = WindowVisibilitySource.of(window, read: { _ in state })
        return window
    }

    /// A few main-actor turns: a start that is not held runs in them.
    private func settle() async {
        for _ in 0..<5 { await PageHostPool.nextTurn() }
    }

    @Test func homeInFrontStartsChromiumAfterTheFirstFrameBeforeCompletion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = StartupTestScheduler()
        let hosting = FakeChromiumHosting()
        hosting.launch = launch.startup
        let view = try makeView(hosting)
        defer { view.close() }
        #expect(view.awaitsFirstShow, "a launch page starts at its show, not when it is made")
        let shown = window(.visible)
        defer { shown.close() }
        shown.contentView?.addSubview(view)
        #expect(!view.awaitsFirstShow)
        await settle()
        #expect(hosting.made.isEmpty, "the visible page asked for Chromium before the first frame")

        launch.startup.firstFrameCommitted()
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.origins == [.restoreVisible])
        #expect(launch.startup.completion == nil, "the visible page must not wait for completion (it holds completion open)")
        #expect(try #require(hosting.made.first).loaded == [descriptor.url(route: "#/home")])
    }

    @Test func homeHiddenAsksForNoChromiumBeforeCompletion() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = StartupTestScheduler()
        let hosting = FakeChromiumHosting()
        hosting.launch = launch.startup
        let view = try makeView(hosting)
        defer { view.close() }
        let covered = window(.hidden)
        defer { covered.close() }
        covered.contentView?.addSubview(view)
        launch.startup.finishRegistration()
        launch.startup.firstFrameCommitted()
        await settle()
        #expect(view.awaitsFirstShow)
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty, "a hidden launch page asked for Chromium before startup completed")

        launch.hand.drain() // the posted completion
        #expect(launch.startup.completion != nil)
        #expect(!view.awaitsFirstShow)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.origins == [.restoreHidden])
    }

    /// A launch page that waited hidden and then shows before completion is the visible one.
    @Test func aHiddenLaunchPageThatShowsIsRestoredVisible() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = StartupTestScheduler()
        let hosting = FakeChromiumHosting()
        hosting.launch = launch.startup
        let view = try makeView(hosting)
        defer { view.close() }
        launch.startup.firstFrameCommitted()
        let shown = window(.visible)
        defer { shown.close() }
        shown.contentView?.addSubview(view)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.origins == [.restoreVisible])
        #expect(launch.startup.completion == nil)
        launch.complete()
        await settle()
        #expect(hosting.made.count == 1, "completion started the page a second time")
    }

    @Test func aPageOpenedAfterTheLaunchStartsAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = StartupTestScheduler()
        launch.complete()
        let hosting = FakeChromiumHosting()
        hosting.launch = launch.startup
        let view = try makeView(hosting)
        defer { view.close() }
        #expect(!view.awaitsFirstShow)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.origins == [.user])
    }

    /// Feature off: the host has no launch, so every page is a person's.
    @Test func withoutALaunchEveryPageStartsAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        #expect(!view.awaitsFirstShow)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(hosting.origins == [.user])
    }

    /// A page closed while it waited for completion never asks for Chromium.
    @Test func aLaunchPageClosedBeforeCompletionNeverStarts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = StartupTestScheduler()
        let hosting = FakeChromiumHosting()
        hosting.launch = launch.startup
        let view = try makeView(hosting)
        view.close()
        launch.complete()
        await settle()
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty)
    }
}
