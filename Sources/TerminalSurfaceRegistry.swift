import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers

// MARK: - Debug Render Instrumentation

enum GhosttyRenderedFrameNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

enum GhosttyTickNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
final class GhosttyMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    private var drawableCount: Int = 0
    private var lastDrawableTime: CFTimeInterval = 0
    private weak var surfaceView: GhosttyNSView?

    func setSurfaceView(_ surfaceView: GhosttyNSView?) {
        lock.lock()
        self.surfaceView = surfaceView
        lock.unlock()
    }

    private func currentSurfaceView() -> GhosttyNSView? {
        lock.lock()
        defer { lock.unlock() }
        return surfaceView
    }

    func debugStats() -> (count: Int, last: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }

    override func nextDrawable() -> CAMetalDrawable? {
        guard let drawable = super.nextDrawable() else { return nil }
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        lock.unlock()
        guard GhosttyRenderedFrameNotificationDemand.isActive else { return drawable }
        if let surfaceView = currentSurfaceView() {
            DispatchQueue.main.async { [weak surfaceView] in
                surfaceView?.enqueueRenderedFrameUpdate()
            }
        }
        return drawable
    }
}

final class TerminalSurfaceRegistry {
    static let shared = TerminalSurfaceRegistry()

    private let lock = NSLock()
    private let surfaces = NSHashTable<AnyObject>.weakObjects()
    private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    private var surfaceFocusPlacements: [UUID: TerminalSurfaceFocusPlacement] = [:]

    private init() {}

    func register(_ surface: TerminalSurface) {
        lock.lock()
        defer { lock.unlock() }
        surfaces.add(surface)
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
    }

    func unregister(_ surface: TerminalSurface) {
        lock.lock()
        let surfaceId = surface.id
        surfaces.remove(surface)
        let stillRegistered = surfaces.allObjects
            .compactMap { $0 as? TerminalSurface }
            .contains { $0 !== surface && $0.id == surfaceId }
        if !stillRegistered {
            surfaceFocusPlacements.removeValue(forKey: surfaceId)
        }
        lock.unlock()

        Task { @MainActor in
            AppDelegate.shared?.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
                reason: "terminalSurface.unregister"
            )
        }
    }

    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }

    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: surface)
        guard runtimeSurfaceOwners[key] == ownerId else { return }
        runtimeSurfaceOwners.removeValue(forKey: key)
    }

    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }

    func surface(id: UUID) -> TerminalSurface? {
        lock.lock()
        let object = surfaces.allObjects.compactMap { $0 as? TerminalSurface }.first { $0.id == id }
        lock.unlock()
        return object
    }

    func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceFocusPlacements[id] == .rightSidebarDock
    }

    func allSurfaces() -> [TerminalSurface] {
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? TerminalSurface }
        lock.unlock()
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// Core Image filter that cuts a pane-local terminal fill out of the shared window backdrop.
final class TerminalSharedBackdropCutoutFilter: CIFilter {
    private static let filterInputKeys = [kCIInputImageKey, kCIInputBackgroundImageKey]
    private static let filterOutputKeys = [kCIOutputImageKey]

    /// The mask image supplied by AppKit for the cutout view.
    @objc dynamic var inputImage: CIImage?

    /// The already-rendered shared backdrop behind the terminal surface.
    @objc dynamic var inputBackgroundImage: CIImage?

    /// Input keys advertised to AppKit's Core Image compositing pipeline.
    override var inputKeys: [String] {
        Self.filterInputKeys
    }

    /// Output keys advertised to AppKit's Core Image compositing pipeline.
    override var outputKeys: [String] {
        Self.filterOutputKeys
    }

    /// The backdrop image with the cutout mask removed.
    override var outputImage: CIImage? {
        guard let inputImage, let inputBackgroundImage else { return nil }
        return CIBlendKernel.destinationOut.apply(
            foreground: inputImage,
            background: inputBackgroundImage
        )
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

enum TerminalSurfaceFocusPlacement: Equatable {
    case workspace
    case rightSidebarDock
}

func recordAgentHibernationTerminalInput(workspaceId: UUID, panelId: UUID) {
    guard AgentHibernationTrackingGate.isEnabled() else { return }
    let recordedAt = Date()
    Task { @MainActor in
        AgentHibernationController.shared.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: recordedAt
        )
    }
}
