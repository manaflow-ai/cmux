#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import UIKit

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. The deliberate strong back-reference keeps the
/// raw UIKit pointer valid until dismantle detaches it; we serialise
/// reads/writes through a lock because callbacks arrive off-main, which lets
/// us safely perform the `Task { @MainActor }` hops below.
final class GhosttySurfaceBridge: @unchecked Sendable {
    // lint:allow lock — sanctioned carve-out: serial low-level primitive hidden behind the type, guarding a single strong ref on the libghostty-callback / typing-latency path; actor rewrite tracked as the GhosttySurfaceView split follow-up.
    private let lock = NSLock()
    // Deliberately STRONG: libghostty holds the raw view pointer
    // (`ghostty_platform_ios_s.uiview`, passUnretained in `makeSurface`), so
    // the view must outlive queued surface operations. Surface creation stores
    // a retained bridge pointer; dismantle detaches this reference to break the
    // view<->bridge cycle, and the host releases the retain only after
    // synchronous C-surface teardown has stopped every callback.
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
