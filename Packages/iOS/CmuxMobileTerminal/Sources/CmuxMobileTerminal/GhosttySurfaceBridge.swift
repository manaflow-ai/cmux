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
    // Deliberately STRONG despite forming a view<->bridge cycle: libghostty
    // holds the raw view pointer (`ghostty_platform_ios_s.uiview`,
    // passUnretained in `makeSurface`), so the view must outlive every queued
    // surface operation. A weak back-reference would let the view deallocate
    // while queued renderer work still dereferences that pointer
    // (use-after-free). The cycle means a closed terminal's view/bridge/
    // surface are reclaimed only by the render-pipeline recovery rebuild, not
    // by dismantle; fixing the leak needs retained-uiview / free-on-dismantle
    // choreography, tracked in
    // https://github.com/manaflow-ai/cmux/issues/7199.
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

    static func fromOpaque(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceBridge? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
    }
}

#endif
