import Foundation

/// Byte-exact envelope for `terminal.render_grid` events.
///
/// Render grids are the hottest event on the wire. The Mac wraps an already
/// encoded frame in this fixed envelope instead of re-serializing it, and the
/// phone recognizes the same bytes and slices the frame back out instead of
/// parsing the envelope, re-serializing the payload and decoding it again.
/// Any frame that does not match exactly takes the generic event path.
public enum MobileRenderGridEventSplice {
    public static let topic = "terminal.render_grid"
    static let prefix = Data(#"{"kind":"event","topic":"terminal.render_grid","payload":"#.utf8)
    static let suffix = UInt8(ascii: "}")

    /// The event envelope around an encoded frame.
    public static func envelope(payloadJSON: Data) -> Data {
        var envelope = prefix
        envelope.append(payloadJSON)
        envelope.append(suffix)
        return envelope
    }

    /// The frame bytes of an envelope produced by ``envelope(payloadJSON:)``,
    /// or nil for any other event.
    public static func payloadJSON(of envelope: Data) -> Data? {
        guard envelope.count > prefix.count + 1,
              envelope.last == suffix,
              envelope.starts(with: prefix) else { return nil }
        let start = envelope.startIndex + prefix.count
        let end = envelope.endIndex - 1
        // The frame is one JSON object; anything else means the envelope
        // only happened to share the prefix.
        guard envelope[start] == UInt8(ascii: "{"), envelope[end - 1] == suffix else { return nil }
        return Data(envelope[start..<end])
    }
}
