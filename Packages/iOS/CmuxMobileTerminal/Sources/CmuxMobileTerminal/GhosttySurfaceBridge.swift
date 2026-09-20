#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
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

    /// Releases the retained UIKit owner after the C surface has been freed.
    /// A failed surface creation has no C-owned userdata retain, so callers
    /// use this path immediately in that case.
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
            guard let surfaceView = self?.surfaceView else { return }
            // A verified replay owns the gate until its readback and layer
            // presentation fence both settle. Ordinary and local-scroll
            // frames still release the gate directly from this callback.
            if surfaceView.handleVerifiedReplayRenderPresented(token: token) {
                surfaceView.finishRenderSubmission(token: token)
            }
        }
    }

    func handleRenderFailed(
        token: UInt64,
        status: ghostty_render_presentation_status_e
    ) {
        Task { @MainActor [weak self] in
            guard let surfaceView = self?.surfaceView else { return }
            MobileDebugLog.anchormux(
                "render.callback_failed token=\(token) status=\(status.rawValue)"
            )
            surfaceView.handleRenderSubmissionFailure(token: token, status: status)
        }
    }

    static let ioWriteCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>?,
        UInt
    ) -> Void = { userdata, buf, len in
        guard let buf, len > 0 else { return }
        let data = Data(bytes: buf, count: Int(len))
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleWrite(data)
    }

    static let renderPresentedCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64
    ) -> Void = { userdata, token in
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleRenderPresented(token: token)
    }

    static let renderFailedCallback: @convention(c) (
        UnsafeMutableRawPointer?,
        UInt64,
        ghostty_render_presentation_status_e
    ) -> Void = { userdata, token, status in
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleRenderFailed(
            token: token,
            status: status
        )
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
