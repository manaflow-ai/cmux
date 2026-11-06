import CCmuxLayoutReducerFFI
import Foundation

/// The app's one input handle (`cmux_input_*`, R-INPUT stage S2): `cmux-focus-core`'s input router, which owns every
/// window's focus. Made once at the composition root and given to each window's ``FocusMachine``, which keeps its focus
/// there under a window key of its own. One in-process call on the caller's thread per request; not thread-safe: the
/// main actor only, as the machines that use it. A machine made with no input (a test, a journal replay) gets its own.
public nonisolated final class FocusInput {
    let handle: OpaquePointer
    private var windowsOpened: UInt64 = 0

    /// A router whose key lanes are bounded by `memory` in bytes (nil: this Mac's physical memory).
    public init(memory: UInt64? = nil) {
        handle = cmux_input_new(memory ?? ProcessInfo.processInfo.physicalMemory)
    }

    deinit {
        cmux_input_free(handle)
    }

    /// Opens a window in the router under a key no other machine of this input had: a window id the app reuses (a
    /// closed window restored) never meets the state of the machine it replaces, whichever is freed first.
    func openWindow() -> [UInt8] {
        windowsOpened &+= 1
        let window = Array("m\(windowsOpened)".utf8)
        _ = window.withUnsafeBufferPointer { cmux_input_window_open(handle, $0.baseAddress, $0.count) }
        return window
    }

    /// Closes `window` in the router: its focus state goes with it. Its one caller is a machine's `deinit`, the only
    /// call into the router the compiler does not keep on the main actor (a machine is freed where its last owner is):
    /// a machine freed off the main thread would race the main thread's calls into this shared router. Debug builds
    /// and tests stop there.
    func closeWindow(_ window: [UInt8]) {
        assert(Thread.isMainThread, "a FocusMachine was freed off the main thread: its window close races the shared input router")
        window.withUnsafeBufferPointer { cmux_input_window_close(handle, $0.baseAddress, $0.count) }
    }
}
