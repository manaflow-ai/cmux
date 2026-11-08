import AppKit
@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextWakeups
import Foundation
import Testing

/// Leo, 2026-11-04: interaction cost stays constant, "the visible window comes first, and off-screen work is deferred".
/// A Reopen Closed under load showed main-thread work nothing on screen needs landing mid-slide: the parked New Tab
/// page's prepare (50-75 ms, its omnibar build). It waits for the motion to land, once, and runs then.
@MainActor @Suite(.serialized)
struct OffscreenWorkWaitsForLandingTests {
    /// A layout whose motion the test starts and lands; the work waiting for the landing, by key (a later call replaces).
    @MainActor final class Layout: LayoutStillness {
        var isInLayoutMotion = false
        var waiting: [String: @MainActor () -> Void] = [:]
        func whenStill(_ key: String, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void) { waiting[key] = work }
        func land() {
            isInLayoutMotion = false
            let ready = waiting
            waiting.removeAll()
            ready.values.forEach { $0() }
        }
    }

    @Test func theNewTabSparesWarmDuringAMotionWaitsForItsLanding() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let pool = services.newTabSpares
        let layout = Layout()
        pool.targetLayout = { layout }
        var made = 0
        pool.makeSpare = { _ in made += 1; return nil }
        defer { pool.makeSpare = nil }

        layout.isInLayoutMotion = true
        pool.warmNow()
        pool.warmNow()
        #expect(made == 0, "a spare was made in the motion's frames")
        #expect(layout.waiting.keys.sorted() == ["NewTabSparePool.warm"], "waiting: \(layout.waiting.keys.sorted())")
        layout.land()
        #expect(layout.waiting.isEmpty, "the landing left work waiting: \(layout.waiting.keys.sorted())")
    }
}
