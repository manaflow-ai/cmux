import AppKit
@testable import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
@testable import MessagesLabHome
import Testing
import UniformTypeIdentifiers

/// Lawrence 2026-10-23: "chief centered profile pic is gone, chief settings gone". #23796 (Leo
/// 2026-10-21) turned Home's chat header off by default: no centered avatar, no "Chief >" name pill,
/// and with the pill went the one click that opens the Chief's settings. By default the chat shows
/// the header again: the avatar centered over the chat, the pill under it.
@MainActor @Suite(.serialized) struct HomeChatHeaderDefaultTests {
    @Test func theChatShowsTheCenteredAvatarAndNamePillByDefault() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(HomeTunables.all)
        TunableStore.shared.set(HomeTunables.chatHeader.key, nil)
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: ConversationID("conv_header"), me: ParticipantID("user_me"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        let host = view.transcript.controller.host
        // The header shows the conversation's title (the store's; this mock conversation has none).
        host.paneHeader.title = "Chief"
        host.layoutSubtreeIfNeeded()
        // Plain values only: a failed expectation that captured a view would reflect AppKit objects.
        let header = host.paneHeader
        let hasHeader = !host.bareTop && !header.bare
        let avatarShown = !header.avatar.isHidden
        let pillShown = !header.pill.isHidden
        let avatarMid = Double(header.convert(NSPoint(x: header.avatar.frame.midX, y: 0), to: host).x)
        let hostMid = Double(host.bounds.midX)
        #expect(hasHeader, "Home's chat has no header by default")
        #expect(avatarShown, "no avatar over the chat")
        #expect(pillShown, "no name pill over the chat")
        #expect(abs(avatarMid - hostMid) <= 1, "the avatar is not centered: \(avatarMid) vs \(hostMid)")
        try Self.writePicture(of: view)
    }

    /// The chat's top as drawn, in `.build/home-chief-header.png` of the package (a fleet step returns
    /// it with `--artifact`); for people, not checked.
    private static func writePicture(of view: NSView) throws {
        let top = NSRect(x: 0, y: view.isFlipped ? 0 : view.bounds.height - 260, width: view.bounds.width, height: 260)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: top) else { return }
        view.cacheDisplay(in: top, to: rep)
        guard let image = rep.cgImage else { return }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-chief-header.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
