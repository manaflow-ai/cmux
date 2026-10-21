import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pane's loading state fades its background out over the page in ``MotionFade/fadeIn`` (120 ms)
/// when a chat's page first paints, which Leo asked for on 2026-10-14 for a chat the app had not
/// loaded. A chat the page drew from a kept tail (tailCache.ts, ``AgentPaneTailCache``) is already
/// on screen in that first frame, so that fade puts 120 ms of softness on the one open that is
/// instant — "instant if cached" (Leo 2026-10-20). The page says which of the two it drew in its
/// paint report; these hold the host to acting on it.
@Suite(.serialized)
@MainActor
struct CachedChatPaintFadeTests {
    /// No daemon: nothing here gets as far as a handshake.
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aPaintReportCarriesWhetherThePageDrewAKeptTail() {
        let cached = AgentPaneRequest(body: ["method": "pane.painted", "params": ["drewKeptTail": true]])
        guard case .painted(let fromKeptTail) = cached else { return #expect(Bool(false), "pane.painted did not parse") }
        #expect(fromKeptTail, "the page said it drew a kept tail and the host did not keep that")
    }

    /// An older page, and the host's own give-up path, say nothing: a chat read for the first time
    /// is what the fade was made for, so the absent fact has to mean cold.
    @Test func aPaintReportWithoutTheFactMeansTheChatWasReadCold() {
        let bare = AgentPaneRequest(body: ["method": "pane.painted", "params": [:]])
        guard case .painted(let fromKeptTail) = bare else { return #expect(Bool(false), "pane.painted did not parse") }
        #expect(!fromKeptTail)
        let noParams = AgentPaneRequest(body: ["method": "pane.painted"])
        guard case .painted(let withoutParams) = noParams else { return #expect(Bool(false), "pane.painted did not parse") }
        #expect(!withoutParams)
    }

    @Test func theModelKeepsWhatTheFirstPaintSaidItDrew() async {
        let cached = AgentPaneModel(host: NoHost())
        _ = await cached.respond(to: AgentPaneRequest(body: ["method": "pane.painted", "params": ["drewKeptTail": true]]))
        #expect(cached.hasPainted)
        #expect(cached.paintedFromKeptTail)
        let cold = AgentPaneModel(host: NoHost())
        _ = await cold.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
        #expect(cold.hasPainted)
        #expect(!cold.paintedFromKeptTail)
    }

    /// The decision itself: a cached chat shows in one frame, a cold chat fades, and the two cases
    /// that never faded (a New Tab page, a page a pane holds hidden for its swap) still do not.
    @Test func onlyAChatReadColdFadesIn() {
        #expect(!AgentPaneView.pageFades(hasNewTab: false, isVisible: true, fromKeptTail: true),
                "a chat drawn from a kept tail is already on screen; fading it in is 120 ms of softness on an instant open")
        #expect(AgentPaneView.pageFades(hasNewTab: false, isVisible: true, fromKeptTail: false))
        #expect(!AgentPaneView.pageFades(hasNewTab: true, isVisible: true, fromKeptTail: false))
        #expect(!AgentPaneView.pageFades(hasNewTab: false, isVisible: false, fromKeptTail: false))
    }
}
