#if os(iOS)
import CmuxMobileDesign
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "appearance")

/// The focused Mac's theme on this phone (ask-87d30da8e5). Each Mac's host serves it on the
/// `appearance` service (`cmux-mobile-host` `appearance.rs`: one frame now and on every change);
/// the newest frame of each linked Mac is kept here. Every Mac's terminal theme goes to
/// ``CmuxMobileTerminalThemes``, and the focused Mac's appearance goes to ``CmuxMobileMacTheme``,
/// which keeps it on disk for the accent. The phone does not take the Mac's wallpaper: the app's
/// own backgrounds stay its stock ones. A Mac whose host predates the service refuses it, and the
/// phone keeps what it had.
@MainActor
public final class MacAppearanceFeed {
    public static let service = "appearance"

    private let theme: CmuxMobileMacTheme
    private let terminalThemes: CmuxMobileTerminalThemes
    /// The newest appearance of each Mac, by Mac id.
    private(set) var latest: [String: CmuxMobileMacAppearance] = [:]
    /// The Mac whose appearance the phone shows.
    private(set) var focusedMacID: String?

    public init(theme: CmuxMobileMacTheme = .shared, terminalThemes: CmuxMobileTerminalThemes = .shared) {
        self.theme = theme
        self.terminalThemes = terminalThemes
    }

    /// The focused Mac changed: its newest theme shows at once.
    public func focus(macID: String?) {
        focusedMacID = macID
        guard let macID, let appearance = latest[macID] else { return }
        theme.apply(appearance)
    }

    /// One `appearance` frame of `macID`.
    func apply(_ message: Data, macID: String) {
        guard let appearance = CmuxMobileMacAppearance.decode(message) else {
            log.error("appearance: unusable frame")
            return
        }
        latest[macID] = appearance
        // Every Mac's terminals take its terminal theme, focused or not.
        terminalThemes.apply(appearance, macID: macID)
        guard macID == focusedMacID else { return }
        theme.apply(appearance)
    }

    /// Reads `macID`'s `appearance` service on `link` until the channel or the link closes.
    public func read(on link: any MacLink, macID: String) async {
        do {
            let channel = try await link.openChannel(service: Self.service, args: [:])
            while let message = try await channel.receive() {
                apply(message, macID: macID)
            }
            if let closed = channel.closedBy, closed.code != "eof" {
                log.info("appearance closed: \(closed.code, privacy: .public)")
            }
        } catch {
            log.info("appearance channel: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
