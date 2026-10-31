import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing

/// The user, 2026-10-31, on Home over a background image: "this looks bad, why is sidebar different
/// color" and "color of the middle part looks bad too". The workspace sidebar, the conversation list,
/// the chat and the chat's header each laid a tint of their own over the window, so over art (and in
/// plain dark and light) the columns were three greys. Home has one veil: the window's own tint. No
/// column and no resting header adds a fill over it.
@MainActor @Suite(.serialized) struct HomeOneVeilTests {
    /// The conversation list paints no scrim of its own over the window's backdrop: it shows the same
    /// tint as the workspace sidebar beside it and the chat after it, in dark and light.
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func theConversationListAddsNoFillOverTheWindow(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        let list = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        list.appearance = appearance
        list.applyColors()
        let alpha = list.layer?.backgroundColor?.alpha ?? 0
        #expect(alpha == 0, "the conversation list lays a fill of alpha \(alpha) over the window's tint")
    }

    /// At rest (no message under the header) the chat's header shows no band: the avatar and the name
    /// pill sit on the chat's own colour, not on a lighter or darker strip.
    @Test func theChatHeaderShowsNoBandWithNothingUnderIt() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, nil)
        TunableStore.shared.set(HomeTunables.topFadeStyle.key, nil)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_veil"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        let host = view.transcript.controller.host
        host.layoutSubtreeIfNeeded()
        host.updateTopFadeScrollEdge()
        let glassShown = host.headerGlass.map { !$0.isHidden && $0.alphaValue > 0 } ?? false
        let backdropShown = !host.headerBackdrop.isHidden && host.headerBackdrop.alphaValue > 0
        #expect(!glassShown, "the header's glass band shows over an empty chat")
        #expect(!backdropShown, "the header's tinted bar shows over an empty chat")
    }
}
