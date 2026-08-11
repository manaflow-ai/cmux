#if canImport(UIKit)
import Foundation
import UIKit

/// Bridges libghostty C callbacks (which run on the IO read thread or
/// other Ghostty-internal threads) onto the main actor where the
/// `GhosttySurfaceView` lives. The bridge lock protects the retained view and
/// the small scrollbar callback gate; UIKit mutations still occur only in the
/// `Task { @MainActor }` hops below.
final class GhosttySurfaceBridge: @unchecked Sendable {
    // lint:allow lock — sanctioned carve-out: serial low-level primitive hidden behind the type, guarding the retained view and callback gate on the libghostty-callback / typing-latency path; actor rewrite tracked as the GhosttySurfaceView split follow-up.
    private let lock = NSLock()
    // Deliberately STRONG: libghostty holds the raw view pointer
    // (`ghostty_platform_ios_s.uiview`, passUnretained in `makeSurface`), so
    // the view must outlive queued surface operations. Surface creation stores
    // a retained bridge pointer; dismantle detaches this reference to break the
    // view<->bridge cycle, and the host releases the retain only after
    // synchronous C-surface teardown has stopped every callback.
    private var _surfaceView: GhosttySurfaceView?
    private var scrollBoundaryGate = ScrollBoundaryCallbackGate()

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

    func beginScrollBoundaryTransaction(id: UInt64) {
        lock.lock()
        scrollBoundaryGate.begin(transactionID: id)
        lock.unlock()
    }

    func commitScrollBoundaryTransaction(
        id: UInt64,
        boundary: TerminalScrollBoundary
    ) -> TerminalScrollBoundary? {
        lock.lock()
        defer { lock.unlock() }
        return scrollBoundaryGate.commit(transactionID: id, boundary: boundary)
    }

    func cancelScrollBoundaryTransaction(id: UInt64) {
        lock.lock()
        scrollBoundaryGate.cancel(transactionID: id)
        lock.unlock()
    }

    func handleScrollBoundary(_ boundary: TerminalScrollBoundary) {
        lock.lock()
        let boundaryToPublish = scrollBoundaryGate.observe(boundary)
        lock.unlock()
        guard let boundaryToPublish else { return }
        Task { @MainActor [weak self] in
            guard let view = self?.surfaceView else { return }
            view.handleScrollBoundaryChange(boundaryToPublish)
            #if DEBUG
            view.recordBottomScrollStressScrollbar(
                total: Int(boundaryToPublish.totalRows),
                offset: Int(boundaryToPublish.viewportOffsetRows),
                len: Int(boundaryToPublish.visibleRows)
            )
            #endif
        }
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
            self?.surfaceView?.handleRenderPresented(token: token)
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
