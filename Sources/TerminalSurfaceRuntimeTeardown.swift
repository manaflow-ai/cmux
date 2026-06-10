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


// MARK: - Surface runtime teardown coordination
final class GhosttySurfaceCallbackContext {
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?
    let surfaceId: UUID

    init(surfaceView: GhosttyNSView, terminalSurface: TerminalSurface) {
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
        self.surfaceId = terminalSurface.id
    }

    var tabId: UUID? {
        terminalSurface?.tabId ?? surfaceView?.tabId
    }

    var runtimeSurface: ghostty_surface_t? {
        terminalSurface?.surface ?? surfaceView?.terminalSurface?.surface
    }
}

// The native pointer has been removed from all main-thread owner state before
// this request is created; this wrapper only transports the one-shot free.
private struct TerminalSurfaceRuntimeTeardownRequest: @unchecked Sendable {
    let id: UUID
    let workspaceId: UUID
    let reason: String
    let surface: ghostty_surface_t
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let freeSurface: @Sendable (ghostty_surface_t) -> Void
#if DEBUG
    let surfaceToken: String
    let workspaceToken: String
#endif

    init(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.callbackContext = callbackContext
        self.freeSurface = freeSurface
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}

private actor TerminalSurfaceRuntimeTeardownCoordinator {
    static let shared = TerminalSurfaceRuntimeTeardownCoordinator()

    private let timeout: Duration = .seconds(5)
    private var pendingReasonsById: [UUID: String] = [:]
    private var queuedRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var isWorkerRunning = false

    func enqueue(_ request: TerminalSurfaceRuntimeTeardownRequest) {
        pendingReasonsById[request.id] = request.reason
        queuedRequests.append(request)
        if !isWorkerRunning {
            isWorkerRunning = true
            Task.detached(priority: .utility) {
                while let request = await self.nextRequestForWorker() {
                    Task {
                        await self.observeTimeout(id: request.id)
                    }
                    await Self.free(request)
                    await self.complete(id: request.id)
                }
            }
        }
    }

    private func nextRequestForWorker() -> TerminalSurfaceRuntimeTeardownRequest? {
        guard !queuedRequests.isEmpty else {
            isWorkerRunning = false
            return nil
        }
        return queuedRequests.removeFirst()
    }

    private nonisolated static func free(_ request: TerminalSurfaceRuntimeTeardownRequest) async {
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.begin surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        request.freeSurface(request.surface)
        if let callbackContext = request.callbackContext {
            await MainActor.run {
                callbackContext.release()
            }
        }
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.end surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
    }

    private func complete(id: UUID) {
        pendingReasonsById.removeValue(forKey: id)
    }

    private func observeTimeout(id: UUID) async {
        do {
            // Genuine teardown deadline: report a stuck native free without blocking close.
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        guard let reason = pendingReasonsById[id] else { return }
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.timeout surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
    }
}

func enqueueTerminalSurfaceRuntimeTeardown(
    id: UUID,
    workspaceId: UUID,
    reason: String,
    surface: ghostty_surface_t,
    callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
    freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
) {
    let request = TerminalSurfaceRuntimeTeardownRequest(
        id: id,
        workspaceId: workspaceId,
        reason: reason,
        surface: surface,
        callbackContext: callbackContext,
        freeSurface: freeSurface
    )
    Task {
        await TerminalSurfaceRuntimeTeardownCoordinator.shared.enqueue(request)
    }
}

func enqueueTerminalSurfaceRuntimeTeardown(
    id: UUID,
    workspaceId: UUID,
    reason: String,
    surface: ghostty_surface_t,
    callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
) {
    enqueueTerminalSurfaceRuntimeTeardown(
        id: id,
        workspaceId: workspaceId,
        reason: reason,
        surface: surface,
        callbackContext: callbackContext,
        freeSurface: { surface in ghostty_surface_free(surface) }
    )
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

