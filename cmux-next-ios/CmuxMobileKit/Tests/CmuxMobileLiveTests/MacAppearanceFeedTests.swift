@testable import CmuxMobileDesign
@testable import CmuxMobileLive
import CmuxMobileTransport
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

    /// Leo, 2026-11-22: "the theming seemed to disappear maybe for the terminal/background". An
    /// `appearance` channel that ends while its link lives is opened again, so the Mac's next
    /// theme still reaches the phone; the read stops only when the link refuses a channel.
    /// Before, it stopped after the first channel and the second frame never arrived.
    @Test func aDroppedAppearanceChannelIsOpenedAgainWhileTheLinkLives() async {
        let terminals = CmuxMobileTerminalThemes(cached: nil)
        let feed = MacAppearanceFeed(theme: Self.theme(), terminalThemes: terminals)
        let link = AppearanceScriptLink(channels: [
            [Self.frame(background: "#101010")],
            [Self.frame(background: "#202020")],
        ])
        await feed.read(on: link, macID: "mac", reopenAfter: .zero)
        #expect(link.opens == 3)
        #expect(terminals.theme(for: "mac")?.background == "#202020")
    }

    /// A whole frame as hostd `Current::message` writes it (theme, null wallpaper, terminal lines
    /// with a 256-entry palette, look, chat): about the 7.5 KB Leo's Mac sends per open.
    static func hostdFrame(background: String = "#1e1e2e") -> Data {
        let palette16 = (0..<16).map { String(format: "\"#%02x%02x%02x\"", $0 * 15, 255 - $0 * 15, ($0 * 37) % 256) }
        var terminal = ["background = \(background)", "foreground = #cdd6f4", "cursor-color = #f5e0dc",
                        "selection-background = #585b70", "selection-foreground = #cdd6f4", "minimum-contrast = 1",
                        "palette-generate = true", "window-colorspace = srgb"]
        terminal += (0..<256).map { String(format: "palette = %d=#%02x%02x%02x", $0, $0, 255 - $0, ($0 * 7) % 256) }
        let lines = terminal.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"theme":{"background":"\(background)","foreground":"#cdd6f4","palette":[\(palette16.joined(separator: ","))],\
        "selection_background":"#585b70","selection_foreground":"#cdd6f4","cursor":"#f5e0dc","accent":"art",\
        "accent_color":"#89b4fa","background_opacity":0.92},"wallpaper":null,"terminal":[\(lines)],\
        "look":{"chrome_style":"glass","hue":212.5,"saturation":0.4,"glass_transparency":0.3,"sidebar_surface":"tinted",\
        "terminal_font":{"family":"JetBrains Mono","size":13.0},"chat":{"sent":"#89b4fa","sent_text":"#1e1e2e"},\
        "groups":{"palette":"vivid","gradient":"soft"}},\
        "chat":{"background":"\(background)","foreground":"#cdd6f4","background_opacity":1.0,"bubbles":{"sent":"#89b4fa","sent_text":"#1e1e2e"}}}
        """
        return Data(json.utf8)
    }

    /// Leo, 2026-11-22: "the theming seemed to disappear maybe for the terminal/background". His
    /// Mac's hostd serves the whole frame on every `appearance` open and the phone reopens it again
    /// and again (link churn). Each open, close and refocus keeps the terminal theme and the app
    /// theme applied: nothing at a close resets them, and the same frame again changes nothing.
    @Test func theThemeStaysAppliedAcrossRepeatedChannelReopens() async {
        let frame = Self.hostdFrame()
        #expect(frame.count > 6_000)
        let decoded = CmuxMobileMacAppearance.decode(frame)
        #expect(decoded != nil, "hostd's whole frame decodes on the phone")
        let terminals = CmuxMobileTerminalThemes(cached: nil)
        let theme = Self.theme()
        let feed = MacAppearanceFeed(theme: theme, terminalThemes: terminals)
        feed.focus(macID: "mac")
        let changes = MacRecorder()
        let observer = NotificationCenter.default.addObserver(forName: CmuxMobileTerminalThemes.didChange, object: terminals, queue: nil) { note in
            let macID = note.userInfo?[CmuxMobileTerminalThemes.macIDKey] as? String ?? ""
            MainActor.assumeIsolated { changes.ids.append(macID) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let reopens = 6
        for _ in 0..<3 {
            let link = AppearanceScriptLink(channels: Array(repeating: [frame], count: reopens))
            await feed.read(on: link, macID: "mac", reopenAfter: .zero)
            #expect(link.opens == reopens + 1)
            // A link going down and the next one coming up (closeAllSessions, setFocus).
            feed.focus(macID: nil)
            #expect(terminals.theme(for: "mac")?.background == "#1e1e2e")
            #expect(theme.palette != nil)
            feed.focus(macID: "mac")
        }
        let terminal = terminals.theme(for: "mac")
        #expect(terminal?.background == "#1e1e2e")
        #expect(terminal?.foreground == "#cdd6f4")
        #expect(terminal?.lines.count == 264)
        #expect(theme.appearance == decoded)
        #expect(theme.palette != nil)
        #expect(theme.chatLook != nil)
        #expect(changes.ids == ["mac"], "the same frame again is not a change")
    }
}

/// A link whose `appearance` channels each deliver their frames and end; once they run out, it
/// refuses channels as a closed link does.
final class AppearanceScriptLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    private let lock = NSLock()
    private var channels: [[Data]]
    private var openCount = 0
    var opens: Int { lock.withLock { openCount } }

    init(channels: [[Data]]) {
        self.channels = channels
        states = AsyncStream { $0.finish() }
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let frames: [Data]? = lock.withLock {
            openCount += 1
            return channels.isEmpty ? nil : channels.removeFirst()
        }
        guard let frames else { throw LinkError(code: "closed", message: "link closed") }
        return AppearanceScriptChannel(frames: frames)
    }
    func ping() async throws -> UInt32 { 1 }
    func close() async {}
}

final class AppearanceScriptChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var frames: [Data]

    init(frames: [Data]) { self.frames = frames }

    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? {
        lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
    }
    func close(code: String, reason: String) async {}
}

@MainActor final class MacRecorder {
    var ids: [String] = []
}
#endif
