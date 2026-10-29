import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextMetrics
import Foundation
import Testing

/// A hibernated or deferred tab has no engine page, so it holds no renderer memory. Next to
/// a Chromium tab in a hidden workspace it is a clear 0, so the workspace still records its sample.
@MainActor @Suite("Hidden workspace capture")
struct HiddenWorkspaceCaptureTests {
    private func deferred() -> DeferredBrowserTab {
        DeferredBrowserTab(id: BrowserTabID(rawValue: "deferred"), engine: .cef, url: nil, title: nil)
    }

    private func hibernated() -> HibernatedBrowserTab {
        HibernatedBrowserTab(id: BrowserTabID(rawValue: "asleep"), engine: .cef, profile: .default,
                             state: BrowserTabState(url: URL(string: "https://example.com/")), favicon: nil,
                             restoreState: .chromium("back-forward"), snapshot: { nil })
    }

    @Test("A tab with no engine page has no frames, also when the frames are unknown")
    func noEnginePageHasNoFrames() {
        let frames = CEFRendererFrames([CEFRendererFrames.Entry(browser: 7, clientID: 11, frames: 1)])
        #expect(WatchdogReporting.rendererFrames(of: deferred(), in: frames)?.isEmpty == true)
        #expect(WatchdogReporting.rendererFrames(of: hibernated(), in: frames)?.isEmpty == true)
        #expect(WatchdogReporting.rendererFrames(of: hibernated(), in: nil)?.isEmpty == true, "host mode")
    }

    @Test("A hidden workspace with a sleeping tab next to a Chromium one records a clear sample")
    func sleepingTabNextToAChromiumOneIsClear() {
        // Renderer 11 hosts the hidden Chromium tab's frame and a popup's (browser 8, no daemon tab).
        let frames = CEFRendererFrames([CEFRendererFrames.Entry(browser: 7, clientID: 11, frames: 1),
                                        CEFRendererFrames.Entry(browser: 8, clientID: 11, frames: 1)])
        let capture = HiddenWorkspaceMemory.Capture(tabs: [
            HiddenWorkspaceMemory.Placement(workspace: "hidden", rendererFrames: frames.frames(ofBrowser: 7)),
            HiddenWorkspaceMemory.Placement(workspace: "hidden", rendererFrames: WatchdogReporting.rendererFrames(of: hibernated(), in: frames)),
            HiddenWorkspaceMemory.Placement(workspace: "hidden", rendererFrames: WatchdogReporting.rendererFrames(of: deferred(), in: frames)),
        ], hiddenWorkspaces: ["hidden"], rendererFrameTotals: frames.totals)

        let snapshot = HiddenWorkspaceMemory.snapshot(capture, pids: [11: 1_100])

        #expect(MemorySampler.attribute(snapshot) { _ in 4 * 1_024 * 1_024 } == ["hidden": .clear(kibibytes: 2 * 1_024)])
    }
}
