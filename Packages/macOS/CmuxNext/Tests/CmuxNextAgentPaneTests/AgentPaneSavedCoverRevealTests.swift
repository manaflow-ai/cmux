import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane

/// A saved transcript stays until the live page reports its drawn frame. Chromium's separate
/// child window ignores its native parent's alpha, so fading that parent leaves OLD text visible
/// through the already-drawn NEW page. This checks the real paint/reveal callbacks, not pixels.
@MainActor @Suite(.serialized)
struct AgentPaneSavedCoverRevealTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane(chromium: Bool) async throws -> (AgentPaneView, NSWindow, NSView) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: chromium, testRoot: true, chromium: hosting))
        if chromium {
            let page = try #require(view.page)
            await page.chromiumStart?.value
            #expect(view.pageDrawsOverCovers)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        view.frame = host.bounds
        let saved = NSTextField(labelWithString: "OLD saved transcript")
        saved.frame = host.bounds
        host.addSubview(saved)
        host.addSubview(view)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        // AgentTabContent.drawLastPage hides this cover while its saved transcript is underneath.
        view.showsLoadingState = false
        view.loadingView.whenRevealed { [weak saved] in saved?.removeFromSuperview() }
        return (view, window, saved)
    }

    private func revealed(_ view: AgentPaneView) async -> Bool {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        view.loadingView.whenRevealed {
            continuation.yield(true)
            continuation.finish()
        }
        for await revealed in stream {
            if revealed { return true }
        }
        return false
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aSavedTranscriptStaysUntilItsPageReportsPaintThenHandsOff(chromium: Bool) async throws {
        let (view, window, saved) = try await pane(chromium: chromium)
        defer { view.page?.close(); window.close() }
        var reveals = 0
        view.loadingView.whenRevealed { reveals += 1 }
        #expect(!view.model.hasPainted)
        #expect(saved.superview != nil)
        #expect(reveals == 0, "the saved transcript must not disappear before the page's paint report")

        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))

        #expect(view.model.hasPainted)
        if chromium {
            #expect(view.pageContent.alphaValue == 1)
            #expect(view.loadingView.leftFading == false,
                    "a child-window page already draws: fading its native parent cannot hide the OLD transcript")
            #expect(saved.superview == nil, "the saved transcript remained beneath the live Chromium frame")
            #expect(reveals == 1, "the cover handoff must complete on the paint-report turn")
        } else {
            #expect(view.loadingView.leftFading == true, "a cold WebKit chat keeps its existing fade")
            if Motion.canAnimate(in: view), Motion.home.duration(.fadeIn) > 0 {
                #expect(saved.superview != nil, "the WebKit cover must stay through its actual fade")
            }
        }
        #expect(await revealed(view))
        #expect(view.pageContent.alphaValue == 1)
        #expect(saved.superview == nil)
        #expect(reveals == 1)
        // A duplicate paint acknowledgement cannot start another reveal.
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
        #expect(reveals == 1)
    }

    @Test(.timeLimit(.minutes(1))) func theWatchdogStillUsesItsExistingRevealWithoutAPageReport() async throws {
        let (view, window, saved) = try await pane(chromium: true)
        defer { view.page?.close(); window.close() }
        #expect(saved.superview != nil)
        // This is the existing loading watchdog's path, not evidence that a new frame drew.
        view.model.markPainted()
        #expect(view.loadingView.leftFading == true, "do not accelerate an unpainted watchdog reveal")
        #expect(await revealed(view))
        #expect(saved.superview == nil)
    }
}
