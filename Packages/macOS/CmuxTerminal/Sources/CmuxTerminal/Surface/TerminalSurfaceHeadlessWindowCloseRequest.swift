import AppKit

/// Transports the hidden bootstrap window from a nonisolated `deinit` to the
/// main actor for closing. `@unchecked Sendable` because the window is
/// exclusively owned by the request from creation until `close()` runs.
struct TerminalSurfaceHeadlessWindowCloseRequest: @unchecked Sendable {
    let window: NSWindow

    @MainActor
    func close() {
        window.contentView = nil
        window.close()
    }
}
