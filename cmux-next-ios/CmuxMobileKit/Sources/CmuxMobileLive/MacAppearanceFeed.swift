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
/// A Mac whose host predates the service refuses it, and the phone keeps what it had.
@MainActor
public final class MacAppearanceFeed {
    public static let service = "appearance"
    public static let wallpaperService = "appearance-wallpaper"
    /// The largest picture taken (hostd serves at most this).
    public static let maxWallpaperBytes = 8 << 20

    private let theme: CmuxMobileMacTheme
    /// The newest appearance of each Mac, by Mac id.
    private(set) var latest: [String: CmuxMobileMacAppearance] = [:]
    /// The Mac whose appearance the phone shows.
    private(set) var focusedMacID: String?

    public init(theme: CmuxMobileMacTheme = .shared) {
        self.theme = theme
    }

    /// The focused Mac changed: its newest appearance shows at once (no fetch; a wallpaper not
    /// cached yet comes with its next frame).
    public func focus(macID: String?) {
        focusedMacID = macID
        if let macID, let appearance = latest[macID], !theme.needsWallpaper(appearance) { theme.apply(appearance) }
    }

    /// One `appearance` frame of `macID`. `fetch` brings the wallpaper's bytes when they are not cached.
    func apply(_ message: Data, macID: String, fetch: (CmuxMobileMacAppearance.Wallpaper) async -> Data?) async {
        guard let appearance = CmuxMobileMacAppearance.decode(message) else {
            log.error("appearance: unusable frame")
            return
        }
        latest[macID] = appearance
        guard macID == focusedMacID else { return }
        var bytes: Data?
        if theme.needsWallpaper(appearance), let wallpaper = appearance.wallpaper {
            bytes = await fetch(wallpaper).flatMap { Self.verified($0, wallpaper) }
        }
        // A newer frame or another Mac's focus came while the picture loaded: that one wins.
        guard macID == focusedMacID, latest[macID] == appearance else { return }
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
