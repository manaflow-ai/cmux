#if os(iOS)
@testable import CmuxMobileBrowserStream
import CmuxMobileDesign
@testable import CmuxMobileWorkspaces
import SwiftUI
import Testing
import UIKit

/// Leo, 2026-11-24 (item 3): "all the connecting... indicators and the graying out of workspaces,
/// nah let's not do that. let's just keep optimistically connecting and reinforcing the
/// connection". A link that is still trying (connecting, reconnecting, "Can't reach"
/// while it redials) draws nothing on any surface: the agent chat's composer chip, the
/// Workspaces and Home banner slot, the chat list, the streamed browser and simulator pages.
/// Only a fact the person can act on still draws (this phone has no network, the Mac is off).
///
/// Fails on feat-cmux-next before this change: there every kind drew a glass chip about
/// 100 pt wide once its quiet bound had passed.
@MainActor struct NoConnectingChipTests {
    static let waiting: [ConnectionChip.Kind] = [.connecting, .reconnecting, .cantReach]

    private static func size(_ view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 402, height: 200))
    }

    @Test func aStillTryingLinkPaintsNoKind() {
        for kind in Self.waiting { #expect(!kind.paints, "\(kind) still paints") }
        #expect(ConnectionChip.Kind.offline.paints, "the phone's own lost network still says so")
        #expect(ConnectionChip.Kind.macOffline.paints, "a Mac that is off still says so")
    }

    /// The chip over the agent chat's composer (`AgentChatConnectionLine`: `.connecting` while the
    /// chat is away from its Mac; a catch-up has no kind, Leo 2026-11-24), past its quiet bound
    /// (`downSince: nil`): no room, nothing drawn. The same for the symbol-only form.
    @Test func aStillTryingChipTakesNoRoom() {
        for kind in Self.waiting {
            let content = ConnectionChip.Content(kind, sentence: "Connecting to Mac Studio…")
            #expect(Self.size(ConnectionChip(content, downSince: nil, retry: {})) == .zero, "\(kind) chip drew")
            #expect(Self.size(ConnectionChip.SymbolOnly(content, downSince: nil)) == .zero, "\(kind) symbol drew")
        }
        let off = ConnectionChip.Content(.macOffline, sentence: "Mac Studio is offline")
        #expect(Self.size(ConnectionChip(off, downSince: nil)).width > 0, "a Mac that is off still draws its chip")
    }

    /// The banner slot (Workspaces, Home, the shell) skips a link state that is still trying, so
    /// it neither draws nor announces it; a failure with something to do still shows.
    @Test func theBannerSlotSkipsAStillTryingLink() {
        #expect(!ConnectionBannerState.connectionFailed.paints)
        #expect(!ConnectionBannerState.reconnecting(to: "Mac Studio").paints)
        #expect(ConnectionBannerState.offline.paints)
        #expect(ConnectionBannerState.macOffline("Mac Studio").paints)
        #expect(ConnectionBannerState.signedOut.paints)
        #expect(ConnectionBannerState.refreshFailed().paints)
        #expect(ConnectionBannerState.waitingForPairing(on: "Mac Studio").paints, "an approval the person must give")
    }

    /// The list rows' and the streamed browser's link states are still-trying ones.
    @Test func listAndBrowserLinkStatesPaintNothing() {
        #expect(!ListStatusRow.State.reconnecting.chip.paints)
        for reason in [StreamedBrowserModel.reconnectingText, StreamedBrowserModel.linkReconnectingText] {
            #expect(StreamedBrowserModel.linkChip(for: reason)?.paints == false, "browser: \(reason)")
        }
    }
}
#endif
