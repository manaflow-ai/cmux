#if canImport(UIKit)
import Foundation
import UIKit

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. A lock protects callback delivery and the
/// minimal renderer host that keeps libghostty's borrowed UIView pointer valid
/// through synchronous surface destruction.
// Safety: `lock` guards every mutable field, and callbacks dereference UIKit
// objects only after hopping to MainActor.
final class GhosttySurfaceBridge: @unchecked Sendable {
    // lint:allow lock — sanctioned carve-out: serial low-level primitive hidden behind the type, guarding callback delivery and the renderer host on the libghostty-callback / typing-latency path; actor rewrite tracked as the GhosttySurfaceView split follow-up.
    private let lock = NSLock()
    // Callback delivery never owns the terminal view. libghostty stores a raw
    // pointer only to the small renderer host UIView, so that host alone stays
    // alive if a queued free stalls after the terminal has been dismantled.
    private weak var _surfaceView: GhosttySurfaceView?
    private var _rendererHostView: UIView?
    private var deliversCallbacks = false

    var surfaceView: GhosttySurfaceView? {
        lock.lock()
        defer { lock.unlock() }
        return deliversCallbacks ? _surfaceView : nil
    }

    func attach(to surfaceView: GhosttySurfaceView, rendererHostView: UIView) {
        lock.lock()
        _surfaceView = surfaceView
        _rendererHostView = rendererHostView
        deliversCallbacks = true
        lock.unlock()
    }

    func detach() {
        lock.lock()
        deliversCallbacks = false
        _surfaceView = nil
        lock.unlock()
    }

    func releaseRendererHostAfterFree() {
        lock.lock()
        deliversCallbacks = false
        _surfaceView = nil
        _rendererHostView = nil
        lock.unlock()
    }

    /// Delivers one renderer continuation only while the terminal is attached.
    /// The explicit result distinguishes a dropped detached continuation from
    /// one handed to the terminal without adding per-frame bookkeeping.
    @MainActor
    @discardableResult
    func requestRenderWakeup() -> Bool {
        guard let surfaceView else { return false }
        surfaceView.drawForWakeup()
        return true
    }

    func handleWrite(_ bytes: Data) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            surfaceView.handleOutboundBytes(bytes)
        }
    }

    func handleCloseSurface(processAlive: Bool) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            NotificationCenter.default.post(
                name: .ghosttySurfaceDidRequestClose,
                object: surfaceView,
                userInfo: ["process_alive": processAlive]
            )
        }
    }

    func handleRenderPresented(token: UInt64) {
        Task { @MainActor [weak self] in
            self?.surfaceView?.handleVerifiedReplayRenderPresented(token: token)
        }
    }

    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}

#endif
