import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// Every window capture entry point runs its window server calls (the window lists, the composite and the
/// blank check) on the system lane of the lanes it is given, never on the main thread
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 059): main reads only the window numbers and the frame.
/// A test table records each blocking seam that runs on the main thread, and the runner counts its system-lane
/// items, so a capture moved back onto main fails both checks.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WindowCaptureLaneTests {
    /// Real lanes that count the system-lane items.
    nonisolated final class CountingRunner: MayBlockRunner {
        let lanes = BackgroundWork(label: "test.capture-lane")
        private let items = Mutex(0)

        /// How many items ran on the system lane.
        var systemItems: Int { items.withLock { $0 } }

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            items.withLock { $0 += 1 }
            return try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            lanes.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    /// A window on screen with one visible child window over it; `close()` closes both.
    struct Fixture {
        let window: NSWindow
        let child: NSWindow

        func close() {
            window.removeChildWindow(child)
            child.close()
            window.close()
        }
    }

    func fixture() -> Fixture {
        _ = NSApplication.shared
        let frame = CGRect(x: 200, y: 200, width: 200, height: 120)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .green
        window.orderFrontRegardless()
        let child = NSWindow(contentRect: frame.insetBy(dx: 40, dy: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.backgroundColor = .red
        window.addChildWindow(child, ordered: .above)
        child.orderFrontRegardless()
        return Fixture(window: window, child: child)
    }

    /// The blocking seams `body` ran on the main thread, by call site.
    func mainThreadSites(_ body: () async -> Void) async -> [String] {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) { await body() }
        await table.flush()
        return table.sites.filter { $0.context == .main }.map(\.location)
        #else
        await body()
        return []
        #endif
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theScreenshotCapturesOnTheSystemLane() async {
        let fixture = fixture()
        defer { fixture.close() }
        let runner = CountingRunner()
        let sites = await mainThreadSites { _ = try? await fixture.window.screenshotImage(on: runner) }
        #expect(sites.isEmpty, "the screenshot waited for the window server on the main thread: \(sites)")
        #expect(runner.systemItems == 1)
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theCompositedImageAndTheSnapshotCaptureOnTheSystemLane() async {
        let fixture = fixture()
        defer { fixture.close() }
        let runner = CountingRunner()
        let sites = await mainThreadSites {
            _ = await fixture.window.compositedImage(on: runner)
            _ = try? await fixture.window.snapshotImage(on: runner)
        }
        #expect(sites.isEmpty, "a composited capture waited for the window server on the main thread: \(sites)")
        #expect(runner.systemItems == 2)
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theChildWindowsCaptureOnTheSystemLane() async throws {
        let fixture = fixture()
        defer { fixture.close() }
        try #require(fixture.child.windowNumber > 0, "the child window has no number on this host")
        let runner = CountingRunner()
        let sites = await mainThreadSites { _ = await fixture.window.childWindowsImage(on: runner) }
        #expect(sites.isEmpty, "the child windows' capture waited for the window server on the main thread: \(sites)")
        #expect(runner.systemItems == 1)
    }

    @Test(.enabled("this host puts windows on screen") { await WindowScreenshotTests.hostShowsWindows() })
    func theFloatingWindowsListAndCaptureOnTheSystemLane() async throws {
        let fixture = fixture()
        defer { fixture.close() }
        try #require(fixture.window.isOnActiveSpace, "the window is not on the active space on this host")
        let runner = CountingRunner()
        let sites = await mainThreadSites {
            _ = await fixture.window.floatingWindows(on: runner)
            _ = await fixture.window.floatingWindowsImage(on: runner)
        }
        #expect(sites.isEmpty, "the floating windows' list waited for the window server on the main thread: \(sites)")
        #expect(runner.systemItems == 2)
    }
}
