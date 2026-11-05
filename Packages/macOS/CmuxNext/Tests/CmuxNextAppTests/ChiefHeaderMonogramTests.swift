import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import MessagesLabHome
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-30 (msg 17682, over a shot of the Home chat header): "bg of chief header is
/// ugly. i dont like chief's default avatar. let's make it simpler, just maybe CH for chief? like
/// in imessage. no profile pic by default." A Chief with no picture of its own shows an
/// iMessage-style monogram (its initials, white, on a grey gradient disc), never a pet character
/// or 🫡; and the header's band is the chat's own background, not a separate glass band.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChiefHeaderMonogramTests {
    /// Home's chat for a Chief named `name`, as the host sets it, laid out in a window of `appearance`.
    private static func header(named name: String, appearance: NSAppearance.Name) -> (HomeNativeTranscriptView, NSWindow) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, nil)
        TunableStore.shared.set(HomeTunables.topFadeStyle.key, nil)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_monogram"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        // The host's call for a Chief with no avatar of its own (HomeHostView.loadAvatar).
        view.headerTitle = name
        view.setChiefAvatar(picture: nil, text: nil)
        container.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// The RGB of the avatar image's pixel at (`x`, `y`) of its `side`-point square, y down.
    private static func pixel(_ image: NSImage, x: CGFloat, y: CGFloat) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    @Test(arguments: [false, true])
    func aChiefWithNoPictureShowsItsInitialsOnAGreyGradient(dark: Bool) throws {
        let (view, window) = Self.header(named: "Chief", appearance: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let header = view.transcript.controller.host.paneHeader
        let initials = header.initials
        #expect(initials == "CH", "the Chief's monogram is CH, got \(initials)")
        let image = try #require(header.avatar.image)
        let side = image.size.width
        // Off the letters, near the disc's top and bottom: grey (no hue), the top lighter than the bottom.
        let top = try #require(Self.pixel(image, x: side / 2, y: side * 0.1))
        let bottom = try #require(Self.pixel(image, x: side / 2, y: side * 0.9))
        for p in [top, bottom] {
            #expect(max(p.r, p.g, p.b) - min(p.r, p.g, p.b) < 0.12, "the disc is grey, got \(p)")
            #expect(p.r > 0.2 && p.r < 0.85, "the disc is a mid grey, not white or black: \(p)")
        }
        #expect(top.r > bottom.r + 0.04, "the disc is a top-to-bottom gradient: top \(top.r), bottom \(bottom.r)")
    }

    @Test func anotherChiefsMonogramIsItsOwnInitials() {
        let (view, window) = Self.header(named: "Scout Two", appearance: .darkAqua)
        defer { window.close() }
        let initials = view.transcript.controller.host.paneHeader.initials
        #expect(initials == "ST")
    }

    @Test func theDefaultChiefsTileIsItsMonogramNotAPetCharacter() {
        #expect(HomeHostView.defaultTileAvatar(picture: nil) == .text("CH"))
        #expect(HomeChiefAvatar.chiefDefault.isMonogram, "the default Chief draws as a monogram")
    }

    @Test func theHeaderBandIsTheChatsOwnBackground() {
        let (view, window) = Self.header(named: "Chief", appearance: .darkAqua)
        defer { window.close() }
        let host = view.transcript.controller.host
        let style = host.topFadeStyle
        let glass = host.headerGlass == nil
        #expect(style == .backgroundTint, "the header's band is the chat background by default, got \(String(describing: style))")
        #expect(glass, "no separate glass band over the header")
    }
}
