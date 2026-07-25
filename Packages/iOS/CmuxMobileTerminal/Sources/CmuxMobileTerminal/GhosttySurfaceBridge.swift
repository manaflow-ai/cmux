#if canImport(UIKit)
import Foundation
import UIKit

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. A lock protects callback delivery and the
/// strong owner reference that keeps libghostty's borrowed platform pointers
/// valid through synchronous surface destruction.
final class GhosttySurfaceBridge: @unchecked Sendable {
    // lint:allow lock — sanctioned carve-out: serial low-level primitive hidden behind the type, guarding callback delivery and surface ownership on the libghostty-callback / typing-latency path; actor rewrite tracked as the GhosttySurfaceView split follow-up.
    private let lock = NSLock()
    // Deliberately strong because libghostty stores a borrowed bridge pointer
    // and a raw UIView pointer. `detach()` disables callback delivery without
    // releasing the view. The queued free releases it only after synchronous
    // Ghostty teardown has stopped every callback and renderer reference.
    private var _surfaceView: GhosttySurfaceView?
    private var deliversCallbacks = false

    var surfaceView: GhosttySurfaceView? {
        lock.lock()
        defer { lock.unlock() }
        return deliversCallbacks ? _surfaceView : nil
    }

    func attach(to surfaceView: GhosttySurfaceView) {
        lock.lock()
        _surfaceView = surfaceView
        deliversCallbacks = true
        lock.unlock()
    }

    func detach() {
        lock.lock()
        deliversCallbacks = false
        lock.unlock()
    }

    func releaseSurfaceViewAfterFree() {
        lock.lock()
        deliversCallbacks = false
        _surfaceView = nil
        lock.unlock()
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
