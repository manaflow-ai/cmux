#if canImport(UIKit)
import CMUXMobileCore
import Foundation

extension GhosttySurfaceView {
    /// Process terminal output and return after the output has been applied.
    ///
    /// The call still performs libghostty output processing on the serial
    /// background output queue. The returned async boundary lets callers apply
    /// per-surface backpressure without blocking the main actor while Ghostty
    /// consumes the chunk.
    /// - Parameter data: VT or PTY bytes to feed into the surface.
    /// - Returns: `true` when the bytes reached the current surface generation,
    ///   or `false` when the caller should reset its delivery queue and replay.
    @discardableResult
    public func processOutputAndWait(_ data: Data) async -> Bool {
        await processOutputAndWait(data, terminalConfigTheme: nil)
    }

    /// Applies raw terminal defaults and matching VT output as one ordered operation.
    ///
    /// The config update and bytes execute consecutively on the surface's serial
    /// Ghostty queue. This preserves reset semantics when a Mac theme changes while
    /// an older render-grid chunk is still in flight.
    /// - Parameters:
    ///   - data: VT or PTY bytes to feed into the surface.
    ///   - terminalConfigTheme: Raw Ghostty defaults captured with these bytes.
    /// - Returns: `true` when the operation reached the current surface generation,
    ///   or `false` when the caller should reset its delivery queue and replay.
    @discardableResult
    public func processOutputAndWait(
        _ data: Data,
        terminalConfigTheme: TerminalTheme?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let operationID = registerPendingOutputApply(
                byteCount: data.count,
                continuation: continuation
            )
            processOutput(data, terminalConfigTheme: terminalConfigTheme) { [weak self] applied in
                self?.completePendingOutputApply(id: operationID, returning: applied)
            }
        }
    }

    /// Enqueues the current raw config defaults on this surface's serial Ghostty queue.
    public func applyTerminalConfigTheme() {
        applyTerminalConfigTheme(terminalConfigTheme, force: false)
    }

    /// Enqueues captured raw config defaults without changing the latest desired theme.
    ///
    /// This lets a rate-limited caller preserve its generation-to-theme pairing while
    /// output reconciliation continues to read ``terminalConfigTheme`` as the newest
    /// desired value.
    /// - Parameter theme: Raw Ghostty defaults captured with the scheduled generation.
    public func applyTerminalConfigTheme(_ theme: TerminalTheme) {
        applyTerminalConfigTheme(theme, force: false)
    }
}
#endif
