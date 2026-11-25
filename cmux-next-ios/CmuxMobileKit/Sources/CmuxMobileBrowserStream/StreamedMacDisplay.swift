import Foundation

/// A paired Mac's own screen as rd/1 on the cmux-wg link the phone already
/// holds: the Mac's `surface` service on the tab key `d~<display>` (hostd
/// `surface.rs`, PROTOCOL.md `surface`, `mac-display-v1`). The same view-only
/// stream as a Cloud desktop's (StreamedCloudDesktop.swift): hostd forwards no
/// phone input for `d~` keys, and the phone sends none. Its video rides the
/// link's media lane, so Screen Sharing can show the Mac without the device
/// hub's WebRTC session.
extension StreamedBrowserDirectory {
    /// The capability a Mac's host lists in `version` when it streams its own displays.
    public nonisolated static let macDisplayCapability = "mac-display-v1"

    /// The `surface` tab key of a Mac display: a CGDirectDisplayID in decimal, no sign, padding
    /// or leading zero (hostd's `mac_display_of`); 0 is the Mac's main display.
    public nonisolated static func macDisplayTab(display: UInt32 = 0) -> String {
        "d~\(display)"
    }

    /// The display of a Mac display tab key, or nil when `tab` is not one (hostd's
    /// `mac_display_of`, so the phone and the Mac read one key the same way).
    public nonisolated static func macDisplay(ofTab tab: String) -> UInt32? {
        guard tab.hasPrefix("d~") else { return nil }
        let digits = tab.dropFirst(2)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.count == 1 || digits.first != "0" else { return nil }
        return UInt32(digits)
    }

    /// A view-only stream of `macID`'s display over its link, or nil when not linked.
    /// `refused` hears the code of a refusal (at open, or the stream ending with one), such
    /// as `unavailable` while Share This Mac is off or `no_surface_host` from a Mac that
    /// does not capture its displays.
    public func macDisplayModel(display: UInt32 = 0, macID: String,
                                refused: @escaping @MainActor @Sendable (String) -> Void) -> StreamedBrowserModel? {
        viewOnlyModel(tab: Self.macDisplayTab(display: display), macID: macID, refused: refused)
    }
}
