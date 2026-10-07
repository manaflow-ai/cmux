import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import Testing

/// nxdog33 and the Settings repro on the GUI host: the tagged app's window is
/// never in front, macOS reports it occluded, and its terminal surfaces stop
/// drawing (``WindowDrawPolicy``). That pause is energy saving; the defects
/// were that (1) `debug.surfaces` and the blank-pane invariant called every
/// such pane blank (nxdog33: `blank: true`, `invariant_violations: 10`), and
/// (2) automation launches had no way to keep terminals drawing for captures.
/// The un-occlude test proves the path the React lead has no live proof of:
/// the moment the window is visible again the surface draws.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct OccludedWindowDrawTests {
    /// Window visibility as the test says, restored after `body`.
    private final class Visibility {
        var onScreen = false
    }

    private static func withPolicy(drawsWhenOccluded: Bool, _ body: (Visibility) async throws -> Void) async throws {
        let (savedDraws, savedOnScreen) = (WindowDrawPolicy.drawsWhenOccluded, WindowDrawPolicy.onScreen)
        defer { (WindowDrawPolicy.drawsWhenOccluded, WindowDrawPolicy.onScreen) = (savedDraws, savedOnScreen) }
        let visibility = Visibility()
        WindowDrawPolicy.onScreen = { _ in visibility.onScreen }
        WindowDrawPolicy.drawsWhenOccluded = drawsWhenOccluded
        try await body(visibility)
    }

    /// A live Ghostty surface hosted in a window that is never put on screen.
    private static func surfaceInWindow() throws -> (TerminalSession, ScriptedTerminalIO, NSWindow) {
        _ = NSApplication.shared
        try #require(GhosttyRuntime.shared.app != nil, "libghostty did not start")
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        return (session, io, window)
    }

    /// Posts an occlusion change for `window`, then waits (bounded, test only)
    /// until `condition` holds.
    private static func occlusionChanged(_ window: NSWindow, until condition: () -> Bool) async {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSurfaceInAnOccludedWindowPausesAndDrawsAtOnceWhenTheWindowIsVisibleAgain() async throws {
        try await Self.withPolicy(drawsWhenOccluded: false) { visibility in
            let (session, io, window) = try Self.surfaceInWindow()
            defer { session.close(); window.close() }
            io.send(.output(Data("MARKER-OCCLUDED\r\n".utf8)))

            await Self.occlusionChanged(window) { session.diagnostics.drawing == false }
            #expect(session.diagnostics.drawing == false, "an occluded window does not draw")
            #expect(session.diagnostics.pause == .windowOccluded)

            visibility.onScreen = true
            await Self.occlusionChanged(window) { session.diagnostics.drawing == true }
            // Ghostty draws the current content on its `.visible` message (renderer Thread.zig).
            #expect(session.diagnostics.drawing == true, "the surface must draw as soon as the window is visible")
            #expect(session.diagnostics.pause == nil)
            #expect(session.diagnostics.isPresentable)

            visibility.onScreen = false
            await Self.occlusionChanged(window) { session.diagnostics.drawing == false }
            #expect(session.diagnostics.pause == .windowOccluded, "occluded again: paused again")
        }
    }

    @Test func anAutomationLaunchKeepsDrawingAnOccludedWindow() async throws {
        try await Self.withPolicy(drawsWhenOccluded: true) { _ in
            let (session, _, window) = try Self.surfaceInWindow()
            defer { session.close(); window.close() }
            await Self.occlusionChanged(window) { session.diagnostics.drawing == true }
            #expect(session.diagnostics.drawing == true)
            #expect(session.diagnostics.pause == nil)
        }
    }

    // MARK: Blank-pane invariant

    private static func paneStatus(windowDrawable: Bool) -> PaneSurfaceStatus {
        let terminal = TerminalSurfaceDiagnostics(
            hasSurface: true, hasContent: true, renderingSuspended: false, drawing: false,
            pause: windowDrawable ? .suspended : .windowOccluded,
            grid: TerminalGridSize(columns: 80, rows: 24), surfaceInHost: true, inWindow: true, hidden: false,
            viewSize: CGSize(width: 480, height: 320), layerSize: CGSize(width: 480, height: 320),
            restoredSnapshots: 0, swappedSurfaces: 0)
        return PaneSurfaceStatus(
            paneKey: "p1", isVisible: true, presence: "visible", selectedTab: "t1", shownTab: "t1", kind: "terminal",
            contentInstalled: true, contentInWindow: true, contentSize: CGSize(width: 480, height: 320),
            terminal: terminal, windowOccluded: !windowDrawable, windowDrawable: windowDrawable)
    }

    @Test func aPanePausedOnlyBecauseItsWindowIsOccludedIsNotBlank() {
        let status = Self.paneStatus(windowDrawable: false)
        #expect(!status.isBlank, "an occluded window draws nothing by design; the invariant cannot judge it")
        guard case .object(let json) = status.json else {
            Issue.record("pane JSON is not an object")
            return
        }
        #expect(json["window_occluded"] == .bool(true))
        #expect(json["content_visible"] == .bool(false), "content_visible stays the truth: nothing is on screen")
    }

    @Test func aNonDrawingPaneInAVisibleWindowIsStillBlank() {
        #expect(Self.paneStatus(windowDrawable: true).isBlank)
    }
}
