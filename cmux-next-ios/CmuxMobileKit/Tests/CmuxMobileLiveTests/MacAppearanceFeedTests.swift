import CryptoKit
@testable import CmuxMobileDesign
@testable import CmuxMobileLive
import Foundation
import Testing

#if os(iOS)
/// ask-87d30da8e5: each Mac's `appearance` frames; the focused Mac's reach the chrome, the
/// wallpaper is fetched once per content id and only when it is what the Mac announced.
@MainActor
@Suite struct MacAppearanceFeedTests {
    static func theme() -> CmuxMobileMacTheme {
        let name = "MacAppearanceFeedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let cache = CmuxMobileMacAppearanceCache(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAppearanceFeedTests-\(UUID().uuidString)", isDirectory: true))
        return CmuxMobileMacTheme(defaults: defaults, cache: cache)
    }

    static let palette8 = #"["#000000","#cc0000","#00cc00","#cccc00","#0000cc","#cc00cc","#00cccc","#cccccc"]"#

    static func frame(background: String, wallpaper: (id: String, bytes: Int)? = nil) -> Data {
        let picture = wallpaper.map { #"{"id":"\#($0.id)","bytes":\#($0.bytes),"tint_opacity":0.6}"# } ?? "null"
        return Data(#"{"theme":{"background":"\#(background)","foreground":"#eeeeee","palette":\#(palette8),"accent":"neutral","background_opacity":1},"wallpaper":\#(picture)}"#.utf8)
    }

    static func id(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func onlyTheFocusedMacPaintsAndAFocusSwitchShowsTheOther() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac-a")
        await feed.apply(Self.frame(background: "#101010"), macID: "mac-a") { _ in nil }
        await feed.apply(Self.frame(background: "#202020"), macID: "mac-b") { _ in nil }
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#101010"))
        feed.focus(macID: "mac-b")
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#202020"))
    }

    @Test func aWallpaperIsFetchedOnceAndOnlyWhenItIsTheAnnouncedOne() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac")
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
        var fetches = 0
        // Bytes that are not the announced picture are dropped: the colors still apply.
        await feed.apply(Self.frame(background: "#101010", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches += 1
            return Data([0, 1, 2, 3, 4, 5, 6, 7])
        }
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#101010"))
        #expect(theme.appearance?.wallpaper?.id == Self.id(picture))
        #expect(theme.needsWallpaper(theme.appearance!))
        // The right bytes are kept under their id; the same picture again is never fetched.
        await feed.apply(Self.frame(background: "#101010", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches += 1
            return picture
        }
        #expect(!theme.needsWallpaper(theme.appearance!))
        await feed.apply(Self.frame(background: "#303030", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches += 1
            return picture
        }
        #expect(fetches == 2)
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#303030"))
    }

    @Test func anUnusableFrameChangesNothing() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac")
        await feed.apply(Data("{}".utf8), macID: "mac") { _ in nil }
        #expect(theme.palette == nil)
        #expect(feed.latest.isEmpty)
    }
}
#endif
