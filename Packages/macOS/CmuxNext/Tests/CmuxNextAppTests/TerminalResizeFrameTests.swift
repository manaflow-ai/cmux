import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CoreFoundation
import IOSurface
import Testing

/// p03-rendering-084 (ghostty-integration-DESIGN.md G1): a resized terminal's frame at its new size (the text
/// reflowed) goes into the Core Animation commit that carries the size whenever the renderer thread has drawn
/// it by then; the main thread never waits for it; and no commit shows an older frame after a newer one
/// (Ghostty orders the pre-commit present and the renderer's own by one frame sequence).
///
/// Runs only with a GhosttyNextKit pin whose present never waits (`GHOSTTY_PRESENT_NEVER_WAITS`).
@MainActor @Suite(.serialized, .enabled(if: TerminalHostFramePresenter.presentNeverWaits))
struct TerminalResizeFrameTests {
    /// A turn whose display work outlasts the renderer's draw (a STRESS layout): the commit carries the
    /// frame at the new size, not the old frame clipped or padded, and a narrowing drag never shows a wider
    /// (older) frame after a narrower one.
    @Test func aSlowTurnsCommitCarriesTheFrameAtTheNewSize() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        var misses: [String] = []
        var widths: [Int] = []
        for step in 1...6 {
            // The display work of this turn: 30 ms just ahead of the commit, after the resize.
            Self.slowTurn(milliseconds: 30)
            let shipped = await fixture.resize(width: 600 - CGFloat(step) * 20)
            if let miss = shipped.miss { misses.append("step \(step): \(miss)") }
            if let width = shipped.width { widths.append(width) }
        }
        #expect(misses.isEmpty, "\(misses)")
        #expect(widths == widths.sorted(by: >), "an older, wider frame came back after a newer one: \(widths)")
    }

    /// The present never waits on the main thread (the waiting one cost up to 4 ms per drag frame): resizes
    /// in fast turns, whose frames are not drawn by the commit, keep each pass under a millisecond and a half.
    @Test func thePresentNeverWaitsForAFrameNotDrawnYet() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        for step in 1...8 { _ = await fixture.resize(width: 600 - CGFloat(step) * 20) }
        #expect(fixture.presenter.passes > 0, "no pre-commit pass ran")
        #expect(fixture.presenter.longestPass < .microseconds(1_500), "a present pass took \(fixture.presenter.longestPass)")
    }

    struct Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let presenter: TerminalHostFramePresenter
        let previousPresenter: TerminalHostFramePresenter?
        let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            previousPresenter = GhosttyRuntime.shared.hostFramePresenter
            presenter = try #require(TerminalHostFramePresenter.makeIfPresentNeverWaits())
            GhosttyRuntime.shared.hostFramePresenter = presenter
            session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = host
            session.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            host.addSubview(session.view)
            window.orderFrontRegardless()
            session.view.layoutSubtreeIfNeeded()
            let text = (0..<12).map { "line \($0) " + String(repeating: "x", count: 50) }.joined(separator: "\r\n")
            io.send(.output(Data(text.utf8)))
            // The renderer's first frame is drawn on the main thread into the layer: a KVO change of its
            // contents, no clock.
            let layer = try #require(session.surfaceView.layer)
            if session.surfaceView.presentedFrame == nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var observation: NSKeyValueObservation?
                    observation = layer.observe(\.contents, options: [.new]) { _, _ in
                        guard observation != nil else { return }
                        observation?.invalidate()
                        observation = nil
                        continuation.resume()
                    }
                }
            }
            try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        }

        func close() {
            io.finish()
            window.close()
            GhosttyRuntime.shared.hostFramePresenter = previousPresenter
            WindowDrawPolicy.drawsWhenOccluded = drew
        }

        /// Resizes the terminal to `width` in one turn: the shown frame's pixel width after that turn's
        /// commit, and what it showed when that was not the frame at the new size.
        func resize(width: CGFloat) async -> (width: Int?, miss: String?) {
            session.view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            session.view.layoutSubtreeIfNeeded()
            let wanted = session.surfaceView.convertToBacking(session.surfaceView.bounds.size)
            let shipped = await TerminalResizeFrameTests.afterCommit { session.surfaceView.presentedFrame.map { ($0.width, $0.height) } }
            guard shipped?.0 != Int(wanted.width) || shipped?.1 != Int(wanted.height) else { return (shipped?.0, nil) }
            return (shipped?.0, "commit carried \(shipped.map { "\($0.0)x\($0.1)" } ?? "none"), size \(Int(wanted.width))x\(Int(wanted.height))")
        }
    }

    /// Runs `read` in a one-shot observer just after this turn's Core Animation commit (order 2,000,001,
    /// `CommitBoundary.order`) and returns its value.
    static func afterCommit<T>(_ read: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            MainRunLoopObserver.once(activities: [.beforeWaiting, .exit], order: 2_000_001) {
                continuation.resume(returning: read())
            }
        }
    }

    /// Makes this turn's display work take `milliseconds` just ahead of the commit (a one-shot observer at
    /// order 1,999,000, before the presenter's): the renderer finishes its frame meanwhile.
    static func slowTurn(milliseconds: UInt32) {
        MainRunLoopObserver.once(activities: [.beforeWaiting, .exit], order: 1_999_000) {
            usleep(milliseconds * 1_000) // test: the turn's own display work, the condition under test
        }
    }
}
