import Foundation
import GhosttyVt

/// Errors surfaced from libghostty-vt calls. Each case maps 1:1 to a
/// `GhosttyResult` value the C library can return.
public enum GhosttyTerminalError: Error, Equatable, Sendable {
    case outOfMemory
    case invalidValue
    case unknown(Int32)

    init?(_ result: GhosttyResult) {
        switch result {
        case GHOSTTY_SUCCESS:
            return nil
        case GHOSTTY_OUT_OF_MEMORY:
            self = .outOfMemory
        case GHOSTTY_INVALID_VALUE:
            self = .invalidValue
        default:
            self = .unknown(result.rawValue)
        }
    }
}

/// A Swift wrapper around the libghostty-vt terminal emulator. Owns a
/// `GhosttyTerminal` handle and feeds raw bytes through Ghostty's VT
/// parser. This is the same parser the macOS Ghostty surface runs, so
/// the resulting grid matches what the Mac shows byte-for-byte.
///
/// Thread safety: the underlying C library is single-threaded. Callers
/// must serialise access (e.g. by holding this on an actor). The class
/// is marked `Sendable` only because the pointer is treated as a
/// reference; callers are responsible for actor isolation.
public final class GhosttyTerminalEmulator: @unchecked Sendable {
    private var handle: GhosttyTerminal?

    /// Create a new terminal emulator sized to the given grid.
    /// `maxScrollback` controls how many history lines the primary
    /// screen retains.
    public init(cols: UInt16, rows: UInt16, maxScrollback: Int = 10_000) throws {
        let options = GhosttyTerminalOptions(
            cols: cols,
            rows: rows,
            max_scrollback: maxScrollback
        )
        var terminal: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &terminal, options)
        if let err = GhosttyTerminalError(result) {
            throw err
        }
        guard let terminal else {
            throw GhosttyTerminalError.unknown(0)
        }
        self.handle = terminal
    }

    deinit {
        if let handle {
            ghostty_terminal_free(handle)
        }
    }

    /// Resize the grid. Reflows the primary screen when wrap is enabled.
    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32 = 7, cellHeightPx: UInt32 = 14) throws {
        guard let handle else { return }
        let result = ghostty_terminal_resize(handle, cols, rows, cellWidthPx, cellHeightPx)
        if let err = GhosttyTerminalError(result) {
            throw err
        }
    }

    /// Reset the terminal (RIS) to a clean state, preserving dimensions.
    public func reset() {
        guard let handle else { return }
        ghostty_terminal_reset(handle)
    }

    /// Feed VT-encoded bytes through the parser. This never throws:
    /// libghostty-vt logs and recovers from malformed input internally
    /// because the input is expected to be untrusted PTY data.
    public func write(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let handle, let base = bytes.baseAddress, bytes.count > 0 else { return }
        ghostty_terminal_vt_write(handle, base, bytes.count)
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            write(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    /// Convenience for unit tests + string-based input. The bytes are
    /// taken from the UTF-8 encoding of the string.
    public func write(string: String) {
        var copy = string
        copy.withUTF8 { bytes in
            write(bytes)
        }
    }

    /// The opaque pointer for callers that need to call the C ABI
    /// directly (e.g. grid_ref + render-state reads while we're still
    /// in the migration window). Will be removed once the Swift
    /// wrapper exposes everything render code needs.
    public var rawHandle: GhosttyTerminal? { handle }
}
