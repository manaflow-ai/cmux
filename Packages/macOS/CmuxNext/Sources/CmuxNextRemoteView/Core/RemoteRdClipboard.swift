import CCmuxRdFFI
public import Foundation

/// The viewer's side of clipboard text sync (cap `clipboard.text`), implemented by the shared Rust
/// core: it decides what goes to the host (a text the host already has is not sent), cuts a long
/// text into paced parts, reassembles the host's, and counts what it refuses. Create one per
/// session, only when welcome lists `clipboard.text`. No I/O, threads or timers inside; not
/// thread-safe: one actor owns an instance, like `RemoteRdCore`.
public nonisolated final class RemoteRdClipboard {
    /// The largest clipboard text, in UTF-8 bytes; a larger one is refused and counted.
    public static let maxTextBytes = Int(CMUX_RD_CLIPBOARD_MAX_TEXT)
    private static let frameMax = Int(CMUX_RD_CLIPBOARD_FRAME_MAX)

    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate.
    public init?() {
        guard let handle = cmux_rd_clipboard_new() else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rd_clipboard_free(handle)
    }

    /// The viewer's clipboard now holds `text`. True when it was queued for the host; false when
    /// the host already has it. Throws for a text over the bound (counted, nothing sent).
    @discardableResult
    public func offer(_ text: String) throws(RemoteRdClipboardError) -> Bool {
        var text = text
        let code = text.withUTF8 { bytes in
            cmux_rd_clipboard_offer(handle, bytes.baseAddress, bytes.count)
        }
        return try RemoteRdClipboardError.check(code) == 1
    }

    /// The next part as a stream frame ready for the carrier, or nil when none may go now.
    public func popFrame(nowMicros: UInt64) -> Data? {
        var buffer = [UInt8](repeating: 0, count: Self.frameMax)
        var length = 0
        let code = buffer.withUnsafeMutableBufferPointer { out in
            cmux_rd_clipboard_pop_frame(handle, nowMicros, out.baseAddress, out.count, &length)
        }
        guard code == 1 else { return nil }
        return Data(buffer[0..<length])
    }

    /// When `popFrame` can give a part next (0 when one is pending); nil when nothing waits.
    public var nextDeadlineMicros: UInt64? {
        let deadline = cmux_rd_clipboard_next_deadline_us(handle)
        return deadline == UInt64.max ? nil : deadline
    }

    /// Offers a control message payload (JSON). The host's text once its last part arrived; nil
    /// for a part of a longer text, another message, or a refused part (counted; the session goes on).
    public func receive(control json: Data) -> String? {
        var text: UnsafePointer<UInt8>?
        var length = 0
        let code = json.withUnsafeBytes { raw in
            cmux_rd_clipboard_on_control(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &text, &length)
        }
        guard code == 1, let text else { return nil }
        // The bytes are valid until the next call on this handle: copy them now.
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF8.self)
    }

    /// Texts and parts refused so far, both directions.
    public var dropped: UInt64 { cmux_rd_clipboard_dropped(handle) }
}

/// Why the core refused a clipboard text.
public nonisolated enum RemoteRdClipboardError: Error, Sendable, Hashable {
    /// Over `RemoteRdClipboard.maxTextBytes`.
    case tooLarge
    /// Not UTF-8, or a handle the core cannot use.
    case invalid

    static func check(_ code: Int32) throws(RemoteRdClipboardError) -> Int {
        guard code >= 0 else { throw code == RemoteRdClipboardError.tooLargeCode ? .tooLarge : .invalid }
        return Int(code)
    }

    private static let tooLargeCode = Int32(CMUX_RD_ERR_TOO_LARGE)
}
