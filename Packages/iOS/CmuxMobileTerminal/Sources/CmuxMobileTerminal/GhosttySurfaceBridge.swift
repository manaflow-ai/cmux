#if canImport(UIKit)
import Foundation
import UIKit

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. The single mutable property is the
/// `weak var surfaceView`; we serialise reads/writes through the main
/// actor, which lets us conform to `Sendable` for the `Task { @MainActor }`
/// hops below.
final class GhosttySurfaceBridge: @unchecked Sendable {
    // lint:allow lock — sanctioned carve-out: serial low-level primitive hidden behind the type, guarding a single weak ref on the libghostty-callback / typing-latency path; actor rewrite tracked as the GhosttySurfaceView split follow-up.
    private let lock = NSLock()
    // Deliberately STRONG: libghostty holds the raw view pointer
    // (`ghostty_platform_ios_s.uiview`, passUnretained in `makeSurface`), so
    // the view must outlive queued surface operations. Surface creation gives
    // libghostty an owned bridge retain; dismantle detaches this reference to
    // break the view<->bridge cycle, and final C-surface destruction releases
    // the bridge only after internal callbacks and app-action leases stop.
    private var _surfaceView: GhosttySurfaceView?

    var surfaceView: GhosttySurfaceView? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _surfaceView
        }
        set {
            lock.lock()
            _surfaceView = newValue
            lock.unlock()
        }
    }

    func attach(to surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
    }

    func detach() {
        surfaceView = nil
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

    static func releaseRetainedOpaque(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).release()
    }
}

#endif
