import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new agent pane is never blank while its page loads and acpmux starts (cx-sj96, nxdog76):
/// its first frame shows a neutral loading state drawn natively, with no wait on the page or on
/// the handshake; the page's first frame (`pane.painted`) replaces it in one step. The bound is
/// a signal, not wall time: the pane is built against a host whose acpmux never answers and is
/// checked before the run loop turns, so nothing the page or the daemon does can count.
@MainActor
@Suite struct AgentPaneFirstFrameTests {
    /// acpmux that never answers the handshake (a daemon start that takes as long as it takes).
    struct SilentHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            // Outlives every test here; a test that ends cancels nothing it waits on.
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
    }

    static func indicators(in view: NSView) -> [StatusIndicatorView] {
        view.subviews.flatMap { child in
            (child as? StatusIndicatorView).map { [$0] } ?? indicators(in: child)
        }
    }

    /// Whether `view` draws inside `root`: neither it nor an ancestor up to `root` is hidden or clear.
    static func shows(_ view: NSView, in root: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.isHidden || node.alphaValue == 0 { return false }
            if node === root { return true }
            current = node.superview
        }
        return false
    }

    static func content(of view: AgentPaneView) -> NSView { view.page.map { $0 as NSView } ?? view.webView }

    @Test func theFirstFrameShowsALoadingStateWithoutWaitingForThePageOrAcpmux() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost())))
        let loading = Self.indicators(in: view).filter { Self.shows($0, in: view) }
        #expect(loading.count == 1, "the pane draws a loading state in its first frame")
        #expect(loading.first?.state == .busy(progress: nil), "a neutral loading mark, never an error or waiting mark")
        #expect(!Self.shows(Self.content(of: view), in: view),
                "the page's frames before its first real one (no hero, Connecting) stay behind it")
    }

    @Test func thePagesFirstFrameReplacesTheLoadingStateInOneStep() async throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost())))
        _ = await view.model.respond(to: .painted)
        #expect(Self.indicators(in: view).allSatisfy { !Self.shows($0, in: view) })
        #expect(Self.shows(Self.content(of: view), in: view))
    }

    @Test func aPaneOverItsLastPagesImageStaysClearUntilThePagePaints() async throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost())))
        view.showsLoadingState = false
        #expect(Self.indicators(in: view).allSatisfy { !Self.shows($0, in: view) }, "the image under it shows through")
        #expect(!Self.shows(Self.content(of: view), in: view))
        _ = await view.model.respond(to: .painted)
        #expect(Self.shows(Self.content(of: view), in: view))
    }
}
