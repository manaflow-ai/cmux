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

enum TerminalOpenURLTarget: Equatable {
    case embeddedBrowser(URL)
    case external(URL)

    var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    #if DEBUG
    cmuxDebugLog("link.resolve input=\(trimmed)")
    #endif
    guard !trimmed.isEmpty else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (empty)")
        #endif
        return nil
    }

    if NSString(string: trimmed).isAbsolutePath {
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(absolutePath) url=\(trimmed)")
        #endif
        return .external(URL(fileURLWithPath: trimmed))
    }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            guard BrowserInsecureHTTPSettings.normalizeHost(parsed.host ?? "") != nil else {
                #if DEBUG
                cmuxDebugLog("link.resolve result=external(invalidHost) url=\(parsed)")
                #endif
                return .external(parsed)
            }
            #if DEBUG
            cmuxDebugLog("link.resolve result=embeddedBrowser url=\(parsed)")
            #endif
            return .embeddedBrowser(parsed)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
        #endif
        return .external(parsed)
    }

    if let webURL = resolveBrowserNavigableURL(trimmed) {
        guard BrowserInsecureHTTPSettings.normalizeHost(webURL.host ?? "") != nil else {
            #if DEBUG
            cmuxDebugLog("link.resolve result=external(bareHost-invalidHost) url=\(webURL)")
            #endif
            return .external(webURL)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=embeddedBrowser(bareHost) url=\(webURL)")
        #endif
        return .embeddedBrowser(webURL)
    }

    guard let fallback = URL(string: trimmed) else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (unparseable)")
        #endif
        return nil
    }
    #if DEBUG
    cmuxDebugLog("link.resolve result=external(fallback) url=\(fallback)")
    #endif
    return .external(fallback)
}

var terminalKeyboardCopyModeIndicatorText: String {
    String(localized: "ghostty.copy-mode.indicator", defaultValue: "vim")
}

private var terminalKeyTableIndicatorDefaultText: String {
    String(localized: "ghostty.key-table.indicator", defaultValue: "key table")
}

var terminalKeyTableIndicatorAccessibilityLabel: String {
    String(localized: "ghostty.key-table.icon.accessibility", defaultValue: "Key table")
}

func terminalKeyTableIndicatorText(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "", "set":
        return terminalKeyTableIndicatorDefaultText
    case "vi", "vim":
        return terminalKeyboardCopyModeIndicatorText
    default:
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? terminalKeyTableIndicatorDefaultText : normalized
    }
}

private func terminalKeyboardCopyModeModifiers(
    _ modifierFlags: NSEvent.ModifierFlags
) -> TerminalKeyboardCopyModeModifiers {
    let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: TerminalKeyboardCopyModeModifiers = []
    if normalized.contains(.command) {
        modifiers.insert(.command)
    }
    if normalized.contains(.shift) {
        modifiers.insert(.shift)
    }
    if normalized.contains(.control) {
        modifiers.insert(.control)
    }
    if normalized.contains(.numericPad) {
        modifiers.insert(.numericPad)
    }
    if normalized.contains(.function) {
        modifiers.insert(.function)
    }
    if normalized.contains(.capsLock) {
        modifiers.insert(.capsLock)
    }
    return modifiers
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeShouldBypassForShortcut(
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags)
    )
}

func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeAction? {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
        hasSelection: hasSelection,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeResolution {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeResolve(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
        hasSelection: hasSelection,
        state: &state,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

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
