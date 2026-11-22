import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileDesign
@testable import CmuxMobileLive

#if os(iOS)
import UIKit

/// Leo, 2026-11-17: "the lack of themeing/background inheriting (these need to be improved)". The
/// agent chat draws hostd's `chat` look (the Mac's theme, its picture under the window's tint, its
/// picked bubble colors); a Mac at its defaults, a host that sends no `chat`, or Match Mac theme
/// off keeps today's stock chat. The rest of the app's chrome stays stock either way.
@MainActor
@Suite struct ChatLookTests {
    static func theme() -> CmuxMobileMacTheme {
        let name = "ChatLookTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return CmuxMobileMacTheme(defaults: defaults, cache: cache())
    }

    static func cache(_ folder: URL? = nil) -> CmuxMobileMacAppearanceCache {
        CmuxMobileMacAppearanceCache(folder: folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatLookTests-\(UUID().uuidString)", isDirectory: true))
    }

    static let palette8 = ##"["#45475a","#f38ba8","#a6e3a1","#f9e2af","#89b4fa","#f5c2e7","#94e2d5","#bac2de"]"##
    static let mochaTheme = ##"{"background":"#1e1e2e","foreground":"#cdd6f4","palette":\##(palette8),"accent":"neutral","background_opacity":1}"##

    static func frame(chat: String?, wallpaper: (id: String, bytes: Int)? = nil) -> Data {
        let picture = wallpaper.map { #"{"id":"\#($0.id)","bytes":\#($0.bytes),"tint_opacity":0.45}"# } ?? "null"
        let chatField = chat.map { #","chat":\#($0)"# } ?? ""
        return Data(##"{"theme":\##(mochaTheme),"wallpaper":\##(picture)\##(chatField)}"##.utf8)
    }

    /// A Mac whose host sends no `chat` (its defaults, or a host before it): the stock chat.
    @Test func noChatFromTheMacKeepsTheStockChat() throws {
        let theme = Self.theme()
        theme.apply(try #require(CmuxMobileMacAppearance.decode(Self.frame(chat: nil))))
        #expect(theme.chatLook == nil)
        #expect(theme.palette != nil, "the accent still follows the Mac")
    }

    /// A theme the person chose: the chat's ground is the theme's background, its style the theme's
    /// dark, its own bubble the theme's raised surface (the Mac's own derivation).
    @Test func aChosenThemeIsTheChatsGroundAndStyle() throws {
        let theme = Self.theme()
        let appearance = try #require(CmuxMobileMacAppearance.decode(
            Self.frame(chat: ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":1}"##)))
        theme.apply(appearance)
        let look = try #require(theme.chatLook)
        #expect(look.background == CmuxMobileRGBA(hex: "#1e1e2e"))
        #expect(look.isDark)
        #expect(look.interfaceStyle == .dark)
        #expect(look.picture == nil)
        #expect(look.backgroundOpacity == 1)
        #expect(look.userBubble == CmuxMobileMacPalette(appearance)?.surfaceRaised)
        #expect(look.userBubbleText == nil)
    }

    /// Match Mac theme off: the stock chat whatever the Mac shows.
    @Test func matchMacOffKeepsTheStockChat() throws {
        let theme = Self.theme()
        theme.matchesMac = false
        theme.apply(try #require(CmuxMobileMacAppearance.decode(
            Self.frame(chat: ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":1}"##))))
        #expect(theme.chatLook == nil)
    }

    /// Bubble colors picked on the Mac are the chat's own bubble and its text.
    @Test func pickedBubbleColorsAreTheUsersBubble() throws {
        let theme = Self.theme()
        theme.apply(try #require(CmuxMobileMacAppearance.decode(Self.frame(
            chat: ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":1,"bubbles":{"sent":"#0a84ff","sent_text":"#ffffff"}}"##))))
        let look = try #require(theme.chatLook)
        #expect(look.userBubble == CmuxMobileRGBA(hex: "#0a84ff"))
        #expect(look.userBubbleText == CmuxMobileRGBA(hex: "#ffffff"))
    }

    /// The Mac's picture: fetched once by content id, checked, kept on disk as the one chat picture,
    /// and shown under the theme color at the window's tint. A frame that no longer names it drops it.
    @Test func thePictureIsFetchedOnceCheckedAndShownUnderTheTint() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatLookTests-\(UUID().uuidString)", isDirectory: true)
        let name = "ChatLookTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let theme = CmuxMobileMacTheme(defaults: defaults, cache: Self.cache(folder))
        let feed = MacAppearanceFeed(theme: theme)
        let picture = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        let id = SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()
        let fetches = ChatLookFetchCount()
        let fetch: MacAppearanceFeed.Fetch = { _ in
            fetches.count += 1
            return picture
        }
        let chat = ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":0.45,"wallpaper":"\##(id)"}"##
        feed.focus(macID: "mac")
        feed.apply(Self.frame(chat: chat, wallpaper: (id, picture.count)), macID: "mac", fetch: fetch)
        await feed.pictureFetch?.value
        await theme.settled()
        let look = try #require(theme.chatLook)
        #expect(look.picture != nil)
        #expect(look.backgroundOpacity == 0.45)
        #expect(fetches.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("chat-wallpaper-\(id).img").path))
        // The same picture again (a color change): not fetched again.
        feed.apply(Self.frame(chat: chat, wallpaper: (id, picture.count)), macID: "mac", fetch: fetch)
        await feed.pictureFetch?.value
        #expect(fetches.count == 1)
        // A frame without the picture: the chat shows the theme color alone.
        feed.apply(Self.frame(chat: ##"{"background":"#1e1e2e","foreground":"#cdd6f4","background_opacity":1}"##), macID: "mac", fetch: fetch)
        await theme.settled()
        #expect(theme.chatLook?.picture == nil)
        #expect(theme.chatLook?.backgroundOpacity == 1)
    }

    /// Bytes that are not the picture the frame names (size or SHA-256) are never kept.
    @Test func aPictureThatIsNotTheNamedOneIsRefused() {
        let wallpaper = CmuxMobileMacAppearance.Wallpaper(id: String(repeating: "ab", count: 32), bytes: 3, tintOpacity: 0.4)
        #expect(MacAppearanceFeed.verified(Data([1, 2, 3]), wallpaper) == nil)
        #expect(MacAppearanceFeed.verified(Data([1, 2]), wallpaper) == nil)
    }
}
#endif

#if os(iOS)
@MainActor final class ChatLookFetchCount {
    var count = 0
}
#endif
