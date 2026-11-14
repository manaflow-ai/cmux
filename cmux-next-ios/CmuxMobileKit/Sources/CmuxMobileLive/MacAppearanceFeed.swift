#if os(iOS)
import CmuxMobileDesign
import CmuxMobileTransport
import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "appearance")

/// The focused Mac's theme and wallpaper on this phone (ask-87d30da8e5). Each Mac's host serves
/// them on the `appearance` service (`cmux-mobile-host` `appearance.rs`: one frame now and on
/// every change); the newest frame of each linked Mac is kept here, and the focused Mac's goes to
/// ``CmuxMobileMacTheme``, which derives the palette, keeps it on disk and paints it. A wallpaper
/// is fetched once per content id (`appearance-wallpaper`); a cached one is never fetched again.
/// The theme shows as soon as a frame arrives or its Mac is focused; the picture follows.
/// A Mac whose host predates the service refuses it, and the phone keeps what it had.
@MainActor
public final class MacAppearanceFeed {
    public static let service = "appearance"
    public static let wallpaperService = "appearance-wallpaper"
    /// The largest picture taken (hostd serves at most this).
    public static let maxWallpaperBytes = 8 << 20

    /// Brings a wallpaper's bytes from one Mac.
    typealias Fetch = @MainActor (CmuxMobileMacAppearance.Wallpaper) async -> Data?

    private let theme: CmuxMobileMacTheme
    private let terminalThemes: CmuxMobileTerminalThemes
    /// The newest appearance of each Mac, by Mac id.
    private(set) var latest: [String: CmuxMobileMacAppearance] = [:]
    /// How to fetch a wallpaper from each linked Mac (its last link's), by Mac id.
    private var fetchers: [String: Fetch] = [:]
    /// The Mac whose appearance the phone shows.
    private(set) var focusedMacID: String?
    /// The wallpaper fetch the focus started, if any (tests await it).
    private(set) var focusFetch: Task<Void, Never>?

    public init(theme: CmuxMobileMacTheme = .shared, terminalThemes: CmuxMobileTerminalThemes = .shared) {
        self.theme = theme
        self.terminalThemes = terminalThemes
    }

    /// The focused Mac changed: its newest theme shows at once, and a wallpaper not cached yet is
    /// fetched from it then (first pairing, or a switch to a Mac whose picture this phone lacks).
    public func focus(macID: String?) {
        focusedMacID = macID
        focusFetch?.cancel()
        focusFetch = nil
        guard let macID, let appearance = latest[macID] else { return }
        theme.apply(appearance)
        guard theme.needsWallpaper(appearance), let fetch = fetchers[macID] else { return }
        // task-owner: focusFetch; one picture fetch per focus, cancelled by the next focus.
        focusFetch = Task { [weak self] in await self?.show(appearance, of: macID, fetch: fetch) }
    }

    /// One `appearance` frame of `macID`. `fetch` brings the wallpaper's bytes when they are not cached.
    func apply(_ message: Data, macID: String, fetch: @escaping Fetch) async {
        guard let appearance = CmuxMobileMacAppearance.decode(message) else {
            log.error("appearance: unusable frame")
            return
        }
        latest[macID] = appearance
        fetchers[macID] = fetch
        // Every Mac's terminals take its terminal theme, focused or not.
        terminalThemes.apply(appearance, macID: macID)
        guard macID == focusedMacID else { return }
        // The theme shows at once; the picture follows when it arrives.
        theme.apply(appearance)
        await show(appearance, of: macID, fetch: fetch)
    }

    /// Fetches `appearance`'s wallpaper when it is not cached, and hands it over if `appearance` is
    /// still `macID`'s newest and `macID` still the focused Mac.
    private func show(_ appearance: CmuxMobileMacAppearance, of macID: String, fetch: Fetch) async {
        guard theme.needsWallpaper(appearance), let wallpaper = appearance.wallpaper else { return }
        let bytes = await fetch(wallpaper).flatMap { Self.verified($0, wallpaper) }
        // A newer frame or another Mac's focus came while the picture loaded: that one wins.
        guard let bytes, !Task.isCancelled, macID == focusedMacID, latest[macID] == appearance else { return }
        theme.apply(appearance, wallpaper: bytes)
    }

    /// `data` when it is the picture `wallpaper` names (its size and SHA-256).
    static func verified(_ data: Data, _ wallpaper: CmuxMobileMacAppearance.Wallpaper) -> Data? {
        guard data.count == wallpaper.bytes, data.count <= maxWallpaperBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == wallpaper.id.lowercased() ? data : nil
    }

    /// Reads `macID`'s `appearance` service on `link` until the channel or the link closes.
    public func read(on link: any MacLink, macID: String) async {
        do {
            let channel = try await link.openChannel(service: Self.service, args: [:])
            while let message = try await channel.receive() {
                await apply(message, macID: macID) { wallpaper in await Self.fetch(wallpaper, on: link) }
            }
            if let closed = channel.closedBy, closed.code != "eof" {
                log.info("appearance closed: \(closed.code, privacy: .public)")
            }
        } catch {
            log.info("appearance channel: \(String(describing: error), privacy: .public)")
        }
    }

    /// The bytes of `wallpaper` from `link`, nil when the Mac shows another one now or they do not arrive.
    static func fetch(_ wallpaper: CmuxMobileMacAppearance.Wallpaper, on link: any MacLink) async -> Data? {
        guard wallpaper.bytes > 0, wallpaper.bytes <= maxWallpaperBytes,
              let channel = try? await link.openChannel(service: wallpaperService, args: ["id": wallpaper.id]) else { return nil }
        var data = Data()
        data.reserveCapacity(wallpaper.bytes)
        do {
            while let chunk = try await channel.receive() {
                data.append(chunk)
                if data.count > wallpaper.bytes {
                    await channel.close(code: "eof", reason: "larger than announced")
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data
    }
}
#endif
