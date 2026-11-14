import CryptoKit
@testable import CmuxMobileDesign
@testable import CmuxMobileLive
import Foundation
import Testing

#if os(iOS)
import UIKit

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

    static let palette8 = ##"["#000000","#cc0000","#00cc00","#cccc00","#0000cc","#cc00cc","#00cccc","#cccccc"]"##

    static func frame(background: String, wallpaper: (id: String, bytes: Int)? = nil) -> Data {
        let picture = wallpaper.map { #"{"id":"\#($0.id)","bytes":\#($0.bytes),"tint_opacity":0.6}"# } ?? "null"
        return Data(##"{"theme":{"background":"\##(background)","foreground":"#eeeeee","palette":\##(palette8),"accent":"neutral","background_opacity":1},"wallpaper":\##(picture)}"##.utf8)
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
        let fetches = FetchCounter()
        // Bytes that are not the announced picture are dropped: the colors still apply.
        await feed.apply(Self.frame(background: "#101010", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches.count += 1
            return Data([0, 1, 2, 3, 4, 5, 6, 7])
        }
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#101010"))
        #expect(theme.appearance?.wallpaper?.id == Self.id(picture))
        #expect(theme.needsWallpaper(theme.appearance!))
        // The right bytes are kept under their id; the same picture again is never fetched.
        await feed.apply(Self.frame(background: "#101010", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches.count += 1
            return picture
        }
        #expect(!theme.needsWallpaper(theme.appearance!))
        await feed.apply(Self.frame(background: "#303030", wallpaper: (Self.id(picture), picture.count)), macID: "mac") { _ in
            fetches.count += 1
            return picture
        }
        #expect(fetches.count == 2)
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

    /// Each Mac's terminals take that Mac's terminal theme, whether or not the phone focuses it and
    /// whatever Match Mac theme says (that switch is the phone's chrome).
    @Test func everyMacsTerminalThemeIsKeptWhateverTheFocusAndTheSwitch() async {
        let theme = Self.theme()
        theme.matchesMac = false
        let terminals = CmuxMobileTerminalThemes(cached: nil)
        let feed = MacAppearanceFeed(theme: theme, terminalThemes: terminals)
        feed.focus(macID: "mac-a")
        let terminal = ##","terminal":["background = #2b0b3f","foreground = #f9e79f","palette = 1=#ff3864"]}"##
        var frame = String(decoding: Self.frame(background: "#202020"), as: UTF8.self)
        frame.removeLast()
        let changed = MacRecorder()
        // Posted on the main thread, delivered there at once (no queue).
        let observer = NotificationCenter.default.addObserver(forName: CmuxMobileTerminalThemes.didChange, object: terminals, queue: nil) { note in
            let mac = note.userInfo?[CmuxMobileTerminalThemes.macIDKey] as? String
            MainActor.assumeIsolated { if let mac { changed.ids.append(mac) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await feed.apply(Data((frame + terminal).utf8), macID: "mac-b") { _ in nil }
        await feed.apply(Self.frame(background: "#101010"), macID: "mac-a") { _ in nil }
        #expect(terminals.theme(for: "mac-b")?.background == "#2b0b3f")
        #expect(terminals.theme(for: "mac-b")?.lines.contains("palette = 1=#ff3864") == true)
        // An older Mac sends no terminal lines: its own colors, not the phone's.
        #expect(terminals.theme(for: "mac-a")?.background == "#101010")
        #expect(changed.ids == ["mac-b", "mac-a"])
        // The same frame again changes nothing.
        await feed.apply(Self.frame(background: "#101010"), macID: "mac-a") { _ in nil }
        #expect(changed.ids == ["mac-b", "mac-a"])
    }

    /// First pairing, or a switch to a Mac whose frame came while another was focused: the focus
    /// shows that Mac's theme at once, even with its wallpaper not cached, and fetches the picture.
    @Test func aFocusShowsTheThemeAtOnceAndFetchesAMissingWallpaper() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac-a")
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let fetches = FetchCounter()
        // mac-b's frame arrives while mac-a is focused: nothing shows, nothing is fetched yet.
        await feed.apply(Self.frame(background: "#404040", wallpaper: (Self.id(picture), picture.count)), macID: "mac-b") { _ in
            fetches.count += 1
            return picture
        }
        #expect(theme.palette == nil)
        #expect(fetches.count == 0)
        feed.focus(macID: "mac-b")
        // The colors are there before the picture.
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#404040"))
        await feed.focusFetch?.value
        #expect(fetches.count == 1)
        #expect(!theme.needsWallpaper(theme.appearance!))
        await theme.settled()
        #expect(theme.wallpaper?.tint == 0.6)
    }
}

/// A fetch count the test's fetch closures share.
@MainActor
final class FetchCounter {
    var count = 0
}
@MainActor final class MacRecorder {
    var ids: [String] = []
}
#endif
