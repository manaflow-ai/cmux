import CmuxNextCompat
public import CmuxNextPhone
import CmuxNextWakeups
import CmuxScreenKit
public import CoreGraphics
public import CoreVideo
import Foundation
import IOSurface
import os
import ScreenCaptureKit

nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-display-capture")

/// One of this Mac's displays captured in this app's process, frames to the main actor: the iPhone's
/// view-only Mac display surface (`d~<display>`, `MacDisplaySurfaceSources`). The capturer is Share
/// This Mac's own (`ScreenCaptureBackend`: ScreenCaptureKit, NV12, IOSurface-backed), never a second
/// one, and it leaves out the same windows (SECURITY: ``CaptureExcludedWindows``, followed while the
/// capture runs). It takes no input. Frames coalesce: the main actor gets the newest one.
@MainActor
public final class MacDisplayCapture {
    /// Why this process cannot capture the screen now; nil when it can. Only reads the grant: no
    /// prompt. Share This Mac's own capture runs in the Screen Sharing helper with the helper's grant,
    /// so a build with the helper needs this app's grant too.
    public nonisolated static func unavailableReason() -> String? {
        CGPreflightScreenCaptureAccess() ? nil : "cmux has no Screen Recording permission for this capture"
    }

    /// The connected display `display` names (`0`: the main display); nil when none is connected.
    public nonisolated static func connected(_ display: CGDirectDisplayID) -> CGDirectDisplayID? {
        let id = display == 0 ? CGMainDisplayID() : display
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains(id) ? id : nil
    }

    /// The iPhone's view-only Mac display sources: a start is granted only while `sharing` (Share This
    /// Mac) reads true and this app may capture a connected display; each source captures with this type.
    public static func surfaceSources(sharing: @escaping @MainActor () -> Bool) -> MacDisplaySurfaceSources {
        MacDisplaySurfaceSources(sharing: sharing) { display in
            if let why = unavailableReason() { throw MacDisplaySurfaceSources.Failure.noScreenRecording(why) }
            guard let id = connected(display) else { throw MacDisplaySurfaceSources.Failure.noDisplay }
            let capture = MacDisplayCapture(display: id, maximumLongEdge: MacDisplaySurfaceSources.maximumLongEdge)
            return SurfaceFrameFeed(start: { frame, ended in capture.start(frame: frame, ended: ended) }, stop: { capture.stop() })
        }
    }

    private let display: CGDirectDisplayID
    private let maximumLongEdge: Int?
    private var backend: ScreenCaptureBackend?
    private var exclusions: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var onFrame: (@MainActor (CVPixelBuffer) -> Void)?
    private let mailbox = Mailbox()

    /// `display`: a connected CGDirectDisplayID (``connected(_:)``). `maximumLongEdge`: the most
    /// pixels on the picture's long edge (the encoder's own limit; nil: the display's size).
    public init(display: CGDirectDisplayID, maximumLongEdge: Int?) {
        self.display = display
        self.maximumLongEdge = maximumLongEdge
    }

    /// Starts capturing: each newest picture goes to `frame`; `ended` once, with why, when the capture
    /// fails or the display is gone. ``stop()`` ends it with no `ended`.
    public func start(frame: @escaping @MainActor (CVPixelBuffer) -> Void, ended: @escaping @MainActor (String) -> Void) {
        guard backend == nil else { return }
        let backend = ScreenCaptureBackend(log: { line in logger.info("\(line, privacy: .public)") }, rules: MacScreenRules.rules)
        // SECURITY: the windows only the person at this Mac may see stay out of the picture, and the
        // list is read again within `CaptureExcludedWindows.recheck` while the capture runs.
        backend.excludedWindowIDs = { CaptureExcludedWindows().windowIDs }
        if let maximumLongEdge { backend.setMaximumLongEdge(maximumLongEdge) }
        exclusions = MacScreenRdHost.watchExcludedWindows { [weak backend] _ in backend?.exclusionsChanged() }
        self.backend = backend
        onFrame = frame
        let mailbox = mailbox, display = display
        // task-owner: the capture's start; stop() cancels it and stops the backend it started
        starting = Task { [weak self] in
            do {
                try await backend.start(frame: { [weak self] buffer, _ in
                    // One delivery per coalesced frame: it hands over the newest one.
                    guard mailbox.post(buffer) else { return }
                    MainDelivery().later { [weak self] in self?.deliver() }
                }, displays: { _, _ in })
                // The backend starts on the main display; another display is picked by its place in
                // the backend's own list (sorted left to right, as ScreenCaptureKit lists them).
                if display != CGMainDisplayID() {
                    guard let index = await Self.index(of: display) else { throw CaptureError(reason: "that display is not connected") }
                    backend.select(display: index)
                }
            } catch {
                guard let self, self.backend === backend else { return }
                self.stop()
                ended("\(error)")
            }
        }
    }

    /// Stops the capture; no `ended`.
    public func stop() {
        starting?.cancel()
        starting = nil
        exclusions?.cancel()
        exclusions = nil
        backend?.stop()
        backend = nil
        onFrame = nil
        _ = mailbox.take()
    }

    private func deliver() {
        guard let buffer = mailbox.take(), let onFrame else { return }
        onFrame(buffer)
    }

    private nonisolated static func index(of display: CGDirectDisplayID) async -> Int? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        return content.displays.sorted { $0.frame.minX < $1.frame.minX }.firstIndex { $0.displayID == display }
    }

    private nonisolated struct CaptureError: Error, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }
}

extension MacDisplayCapture {
    /// The newest picture not yet delivered, as its IOSurface (thread-safe, so it crosses to the main
    /// actor as is): a frame replaces the waiting one, so the main actor gets at most one hop per
    /// delivery however fast the display changes. A waiting surface holds a use count, so
    /// ScreenCaptureKit's pool does not hand it out for a new frame before the main actor wraps it.
    nonisolated final class Mailbox: Sendable {
        private let slot = Mutex<IOSurface?>(nil)

        /// Holds `buffer`'s surface; true when nothing was waiting (the caller schedules one delivery).
        nonisolated func post(_ buffer: CVPixelBuffer) -> Bool {
            guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return false }
            IOSurfaceIncrementUseCount(surface)
            let dropped = slot.withLock { waiting in
                defer { waiting = surface }
                return waiting
            }
            guard let dropped else { return true }
            IOSurfaceDecrementUseCount(dropped)
            return false
        }

        /// The waiting picture as a pixel buffer for the encoder; nil when none waits.
        nonisolated func take() -> CVPixelBuffer? {
            guard let surface = slot.withLock({ waiting in
                defer { waiting = nil }
                return waiting
            }) else { return nil }
            defer { IOSurfaceDecrementUseCount(surface) }
            var buffer: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &buffer) == kCVReturnSuccess else { return nil }
            return buffer?.takeRetainedValue()
        }
    }
}
