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


// MARK: - Terminal surface registry
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

