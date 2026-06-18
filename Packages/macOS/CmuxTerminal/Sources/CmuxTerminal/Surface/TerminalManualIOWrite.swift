import Foundation

/// Heap-allocated userdata for a `TerminalSurface` created in libghostty
/// MANUAL I/O mode.
///
/// In MANUAL mode ghostty spawns no process and owns no PTY: bytes the user
/// types are delivered to `onWrite` instead of a PTY, and output is injected
/// with `ghostty_surface_process_output`. cmux uses this for remote-tmux pane
/// display surfaces.
final class TerminalManualIOWriteBox {
    /// Invoked with bytes the user typed into the surface. Runs on ghostty's
    /// I/O thread, so the closure must be Sendable and hop to the main actor
    /// itself before touching MainActor state.
    let onWrite: @Sendable (Data) -> Void

    init(onWrite: @escaping @Sendable (Data) -> Void) {
        self.onWrite = onWrite
    }
}

/// C trampoline matching `ghostty_io_write_cb` for MANUAL-mode surfaces.
let terminalManualIOWriteCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt
) -> Void = { userdata, bytes, len in
    guard let userdata, let bytes, len > 0 else { return }
    let box = Unmanaged<TerminalManualIOWriteBox>.fromOpaque(userdata).takeUnretainedValue()
    let count = Int(len)
    let data = bytes.withMemoryRebound(to: UInt8.self, capacity: count) { rebound in
        Data(buffer: UnsafeBufferPointer(start: rebound, count: count))
    }
    box.onWrite(data)
}
