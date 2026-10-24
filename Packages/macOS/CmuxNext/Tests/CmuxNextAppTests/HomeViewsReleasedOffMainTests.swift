import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
import Testing

/// A Home view whose last reference goes on another thread (a task, a socket handler, a closing window's
/// teardown) still stops what it started: its transcript and, for New Message, the composer's own store.
/// The deinits returned early off the main thread, so those kept running after the view was gone.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HomeViewsReleasedOffMainTests {
    /// Holds a view so a background thread can drop the last reference.
    final class Box<View>: @unchecked Sendable { // touched by one thread at a time: set here, cleared there
        var view: View?
        init(_ view: View) { self.view = view }
    }

    /// Drops `box`'s view on a background thread, then waits (main turns, bounded) for `done`.
    private static func releaseOffMain<View>(_ box: Box<View>, until done: @escaping @MainActor () -> Bool) async -> Bool {
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            Thread { box.view = nil; finished.resume() }.start()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10)) // test harness: the main-actor cleanup runs on a later turn
        }
        return done()
    }

    @Test func aHomeHostViewReleasedOffMainStopsItsTranscript() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let box = Box(HomeHostView(services: services, conversation: ConversationID("conv_released_off_main").rawValue))
        let transcript = try #require(box.view?.transcript)
        #expect(!transcript.stopped)
        let stopped = await Self.releaseOffMain(box) { transcript.stopped }
        #expect(stopped, "the transcript of a Home view released off the main thread was never stopped")
    }

    @Test func aNewMessageViewReleasedOffMainStopsItsComposerAndStore() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let box = Box(HomeNewMessageView(services: services))
        let composer = try #require(box.view?.composer)
        let stopped = await Self.releaseOffMain(box) { composer.stopped }
        #expect(stopped, "the New Message composer released off the main thread was never stopped")
    }
}
