import Foundation

/// Rectangle encodings and pseudo-encodings (RFC 6143 section 7.7 and the
/// community registry) this client understands.
public enum RFBEncoding: Int32, Sendable, CaseIterable {
    case raw = 0
    case copyRect = 1
    case rre = 2
    case hextile = 5
    case zlib = 6
    case zrle = 16
    /// Pseudo: the server resized the framebuffer.
    case desktopSize = -223
    /// Pseudo: no more rectangles in this update (count was 0xFFFF).
    case lastRect = -224
    /// Pseudo: the cursor shape, drawn by the client.
    case cursor = -239
    /// Pseudo: the framebuffer size plus the layout of its screens (displays).
    case extendedDesktopSize = -308

    /// What the client advertises, most preferred first. ZRLE and Zlib cut
    /// bandwidth on real networks; Hextile and RRE cover older servers;
    /// CopyRect makes scrolling and window moves cheap; Raw always works.
    public static func advertised(localCursor: Bool) -> [RFBEncoding] {
        var list: [RFBEncoding] = [.copyRect, .zrle, .zlib, .hextile, .rre, .raw, .extendedDesktopSize, .desktopSize, .lastRect]
        if localCursor { list.append(.cursor) }
        return list
    }
}
