import AppKit
import Testing

@testable import CmuxBrowser

/// Tests that replace process-wide `NSPasteboard` lookups: the drag
/// pasteboard hook (``BrowserReplDragPasteboardRedirect``) and the stand-in
/// system pasteboard the page clipboard tests use so that a leaking build
/// never touches the person's clipboard. They run in one serialized suite;
/// the nested suites must not run alongside each other.
@MainActor
@Suite("Browser REPL pasteboards", .serialized)
struct BrowserReplPasteboardTests {
    @MainActor
    @Suite("Drag pasteboard lookups", .serialized)
    struct Lookups {
        /// WebKit handling a web content process's message runs on its own
        /// run-loop turn; WebKit called from AppKit or cmux code is an
        /// action in some web view. Image sequences as observed on macOS 26.
        @Test func lookupsAreClassifiedByWhatCalledWebKit() {
            typealias Origin = BrowserReplDragPasteboardRedirect.LookupOrigin
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["WebCore", "WebKit", "JavaScriptCore", "CoreFoundation"]) == Origin.webKitOnItsOwnTurn)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["WebKit", "libdispatch.dylib"]) == Origin.webKitOnItsOwnTurn)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["WebCore", "WebKit", "AppKit"]) == Origin.webKitCalledByTheApp)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["WebCore", "WebKit", "cmux"]) == Origin.webKitCalledByTheApp)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["WebCore", "WebKit"]) == Origin.webKitCalledByTheApp)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: ["AppKit", "WebKit", "CoreFoundation"]) == Origin.notWebKit)
            #expect(BrowserReplDragPasteboardRedirect.origin(ofCallerImages: []) == Origin.notWebKit)
        }

        /// The clipboard (the general pasteboard) is never redirected, for
        /// WebKit or anyone else.
        @Test func theGeneralPasteboardIsNeverRedirected() async {
            let capture = BrowserAutomationDragCapture()
            defer { capture.finish() }
            #expect(await capture.openPasteboardWindow())
            let general = NSPasteboard.Name.general.rawValue
            for origin in [BrowserReplDragPasteboardRedirect.LookupOrigin.notWebKit, .webKitOnItsOwnTurn, .webKitCalledByTheApp] {
                #expect(BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: general, origin: origin) == nil)
            }
        }
    }
}

/// A clock that moves only when a test advances it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Int: Sleeper] = [:]
    private var nextSleeper = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock { () -> Int in
            nextSleeper += 1
            return nextSleeper
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let ids = sleepers.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Waits until `count` sleeps are pending, for at most 30 s of real
    /// time, so code that never sleeps fails the test instead of hanging it.
    func waitForSleepers(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if lock.withLock({ sleepers.count }) >= count { return }
            await Task.yield()
        }
    }
}
