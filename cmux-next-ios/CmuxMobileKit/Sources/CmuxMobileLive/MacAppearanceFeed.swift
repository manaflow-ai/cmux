#if os(iOS)
import CmuxMobileDesign
import CmuxMobileTransport
import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "appearance")

/// The focused Mac's theme on this phone (ask-87d30da8e5). Each Mac's host serves it on the
/// `appearance` service (`cmux-mobile-host` `appearance.rs`: one frame now and on every change);
/// the newest frame of each linked Mac is kept here. Every Mac's terminal theme goes to
/// ``CmuxMobileTerminalThemes``, and the focused Mac's appearance goes to ``CmuxMobileMacTheme``,
/// which keeps it on disk for the accent and the agent chat's look. The app's own chrome stays the
/// stock one. When the frame's `chat` names the Mac's picture, the chat shows it: the picture is
/// fetched once per content id (`appearance-wallpaper`, at most ``maxWallpaperBytes``, its size
/// and SHA-256 checked) and kept on disk, one at a time; a cached one is never fetched again. A Mac
/// whose host predates the service refuses it, and the phone keeps what it had.
@MainActor
public final class MacAppearanceFeed {
    public static let service = "appearance"
    public static let wallpaperService = "appearance-wallpaper"
    /// The largest picture taken (hostd serves at most this).
    public nonisolated static let maxWallpaperBytes = 8 << 20

    /// Brings a picture's bytes from one Mac.
    typealias Fetch = @MainActor (CmuxMobileMacAppearance.Wallpaper) async -> Data?

    private let theme: CmuxMobileMacTheme
    private let terminalThemes: CmuxMobileTerminalThemes
    /// The newest appearance of each Mac, by Mac id.
    private(set) var latest: [String: CmuxMobileMacAppearance] = [:]
    /// How to fetch a picture from each linked Mac (its last link's), by Mac id.
    private var fetchers: [String: Fetch] = [:]
    /// The Mac whose appearance the phone shows.
    private(set) var focusedMacID: String?
    /// The picture fetch in flight, if any (tests await it); the next frame or focus cancels it.
    private(set) var pictureFetch: Task<Void, Never>?

    /// The picture id ``pictureFetch`` brings: a frame naming the same one keeps that fetch.
    private(set) var fetchingID: String?

    public init(theme: CmuxMobileMacTheme = .shared, terminalThemes: CmuxMobileTerminalThemes = .shared) {
        self.theme = theme
        self.terminalThemes = terminalThemes
        // Match Mac theme turned back on: fetch the focused Mac's picture if this phone lacks it.
        theme.pictureWanted = { [weak self] in
            guard let self, let macID = self.focusedMacID, let appearance = self.latest[macID] else { return }
            self.fetchPicture(of: appearance, macID: macID)
        }
    }

    /// The focused Mac changed: its newest theme shows at once, and a chat picture not cached yet
    /// is fetched from it then.
    public func focus(macID: String?) {
        focusedMacID = macID
        guard let macID, let appearance = latest[macID] else { return }
        theme.apply(appearance)
        fetchPicture(of: appearance, macID: macID)
    }

    /// One `appearance` frame of `macID`. `fetch` brings the chat picture's bytes when they are not
    /// cached (nil: this frame's picture is not fetched).
    func apply(_ message: Data, macID: String, fetch: Fetch? = nil) {
        guard let appearance = CmuxMobileMacAppearance.decode(message) else {
            log.error("appearance: unusable frame")
            return
        }
        latest[macID] = appearance
        if let fetch { fetchers[macID] = fetch }
        // Every Mac's terminals take its terminal theme, focused or not.
        terminalThemes.apply(appearance, macID: macID)
        guard macID == focusedMacID else { return }
        // The theme shows at once; the picture follows when it arrives.
        theme.apply(appearance)
        fetchPicture(of: appearance, macID: macID)
    }

    /// Fetches `appearance`'s picture (the Mac's wallpaper; the chat shows it when its `chat` names it) when it is not cached, and hands it over if
    /// `appearance` is still `macID`'s newest and `macID` still the focused Mac.
    private func fetchPicture(of appearance: CmuxMobileMacAppearance, macID: String) {
        let wanted = theme.needsChatWallpaper(appearance) ? appearance.wallpaper : nil
        // A frame naming the picture already on its way (a color change, the same frame again)
        // keeps that fetch: one download per content id.
        if let wanted, wanted.id == fetchingID, pictureFetch != nil { return }
        pictureFetch?.cancel()
        pictureFetch = nil
        fetchingID = nil
        guard let wallpaper = wanted, let fetch = fetchers[macID] else { return }
        fetchingID = wallpaper.id
        // task-owner: pictureFetch; one per picture id, cancelled by a frame or focus that names another.
        pictureFetch = Task { [weak self] in
            let data = await fetch(wallpaper)
            // Up to 8 MB of SHA-256: never on the main actor.
            var bytes: Data?
            if let data {
                bytes = await Task.detached(priority: .utility) { Self.verified(data, wallpaper) }.value
            }
            guard let self else { return }
            if self.fetchingID == wallpaper.id {
                self.fetchingID = nil
                self.pictureFetch = nil
            }
            // Another Mac's focus, or a frame naming another picture, came meanwhile: that one wins.
            // A newer frame naming this same picture (a color change) gets it.
            guard let bytes, !Task.isCancelled, macID == self.focusedMacID,
                  let newest = self.latest[macID], newest.wallpaper?.id == wallpaper.id else { return }
            self.theme.apply(newest, chatWallpaper: bytes)
        }
    }

    /// `data` when it is the picture `wallpaper` names (its size and SHA-256).
    nonisolated static func verified(_ data: Data, _ wallpaper: CmuxMobileMacAppearance.Wallpaper) -> Data? {
        guard data.count == wallpaper.bytes, data.count <= maxWallpaperBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == wallpaper.id.lowercased() ? data : nil
    }

    /// The first wait before an ended `appearance` channel is opened again; it doubles up to
    /// ``reopenMaxDelay`` and starts over after a frame.
    public static let reopenDelay: Duration = .seconds(1)
    public static let reopenMaxDelay: Duration = .seconds(60)

    /// Reads `macID`'s `appearance` service on `link` for as long as the link lives. hostd never
    /// ends the channel itself: it waits for the next change (`appearance.rs` `serve`). So a
    /// channel that ends while the link still opens channels was dropped, and it is opened again;
    /// before, the read stopped there and the Mac's theme stopped arriving until the next link.
    /// A refused open or a closed link stops the read. A Mac whose host ends the channel at once
    /// is asked again at most once every ``reopenMaxDelay``.
    public func read(on link: any MacLink, macID: String, reopenAfter firstDelay: Duration = MacAppearanceFeed.reopenDelay) async {
        var delay = firstDelay
        while !Task.isCancelled {
            let channel: any LinkChannel
            do {
                channel = try await link.openChannel(service: Self.service, args: [:])
            } catch {
                log.info("appearance channel: \(String(describing: error), privacy: .public)")
                return
            }
            do {
                while let message = try await channel.receive() {
                    delay = firstDelay
                    apply(message, macID: macID) { wallpaper in await Self.fetch(wallpaper, on: link) }
                }
                log.info("appearance closed: \(channel.closedBy?.code ?? "eof", privacy: .public); reopening")
            } catch {
                log.info("appearance channel ended: \(String(describing: error), privacy: .public); reopening")
            }
            do { try await Task.sleep(for: delay) } catch { return }
            delay = min(delay * 2, Self.reopenMaxDelay)
        }
    }

    /// The bytes of `wallpaper` from `link`, nil when the Mac shows another one now or they do not
    /// arrive. Stops reading past the announced size.
    static func fetch(_ wallpaper: CmuxMobileMacAppearance.Wallpaper, on link: any MacLink) async -> Data? {
        guard wallpaper.bytes > 0, wallpaper.bytes <= maxWallpaperBytes,
              let channel = try? await link.openChannel(service: wallpaperService, args: ["id": wallpaper.id]) else { return nil }
        var data = Data()
        data.reserveCapacity(wallpaper.bytes)
        do {
            while let chunk = try await channel.receive() {
                // A newer frame or focus cancelled this picture: stop reading it now.
                if Task.isCancelled {
                    await channel.close(code: "eof", reason: "cancelled")
                    return nil
                }
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
