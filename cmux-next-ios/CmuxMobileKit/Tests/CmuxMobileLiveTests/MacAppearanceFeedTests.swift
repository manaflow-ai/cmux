@testable import CmuxMobileDesign
@testable import CmuxMobileLive
import Foundation
import Testing

#if os(iOS)
import UIKit

/// ask-87d30da8e5: each Mac's `appearance` frames; the focused Mac's reach the theme store (the
/// accent), every Mac's reach its terminals, and no wallpaper is taken.
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

    @Test func onlyTheFocusedMacPaintsAndAFocusSwitchShowsTheOther() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac-a")
        feed.apply(Self.frame(background: "#101010"), macID: "mac-a")
        feed.apply(Self.frame(background: "#202020"), macID: "mac-b")
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#101010"))
        feed.focus(macID: "mac-b")
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#202020"))
    }

    /// A Mac that shows a wallpaper: its theme still applies, and the phone keeps no picture.
    @Test func aFrameNamingAWallpaperAppliesItsThemeAndKeepsNoPicture() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAppearanceFeedTests-\(UUID().uuidString)", isDirectory: true)
        let name = "MacAppearanceFeedTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let theme = CmuxMobileMacTheme(defaults: defaults, cache: CmuxMobileMacAppearanceCache(folder: folder))
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac")
        feed.apply(Self.frame(background: "#101010", wallpaper: ("ab12", 8)), macID: "mac")
        await theme.settled()
        #expect(theme.palette?.bg == CmuxMobileRGBA(hex: "#101010"))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["appearance.json"])
    }

    @Test func anUnusableFrameChangesNothing() async {
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme)
        feed.focus(macID: "mac")
        feed.apply(Data("{}".utf8), macID: "mac")
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
        feed.apply(Data((frame + terminal).utf8), macID: "mac-b")
        feed.apply(Self.frame(background: "#101010"), macID: "mac-a")
        #expect(terminals.theme(for: "mac-b")?.background == "#2b0b3f")
        #expect(terminals.theme(for: "mac-b")?.lines.contains("palette = 1=#ff3864") == true)
        // An older Mac sends no terminal lines: its own colors, not the phone's.
        #expect(terminals.theme(for: "mac-a")?.background == "#101010")
        #expect(changed.ids == ["mac-b", "mac-a"])
        // The same frame again changes nothing.
        feed.apply(Self.frame(background: "#101010"), macID: "mac-a")
        #expect(changed.ids == ["mac-b", "mac-a"])
    }
}

@MainActor final class MacRecorder {
    var ids: [String] = []
}
#endif
