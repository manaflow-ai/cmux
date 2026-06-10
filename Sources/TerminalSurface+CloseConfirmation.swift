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


// MARK: - Close confirmation
extension TerminalSurface {
    func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

#if DEBUG
    @MainActor
    func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        needsConfirmCloseOverrideForTesting = value
    }

    @MainActor
    func debugRuntimeSurfaceCreateAttemptCountForTesting() -> Int {
        runtimeSurfaceCreateAttemptCountForTesting
    }

    @MainActor
    func debugBackgroundSurfaceStartQueuedForTesting() -> Bool {
        backgroundSurfaceStartQueued
    }

    @MainActor
    func debugHasHeadlessStartupWindowForTesting() -> Bool {
        headlessStartupWindow != nil
    }

    @MainActor
    func debugPendingSocketInputForTesting() -> (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (keyEvents: 0, pasteTextItems: 0, inputTextItems: 0, processOutputItems: 0)
        ) { counts, item in
            switch item {
            case .key:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        ghostty_surface_free(surfaceToFree)
        callbackContext?.release()
    }

    /// Test-only helper to simulate a stale Swift wrapper whose native surface
    /// was already freed out-of-band.
    @MainActor
    func replaceSurfaceWithFreedPointerForTesting() {
        guard !runtimeSurfaceFreedOutOfBandForTesting else { return }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        callbackContext?.release()
    }

    @MainActor
    func installRuntimeSurfaceForTesting(_ runtimeSurface: ghostty_surface_t) {
        surface = runtimeSurface
        portalLifecycleState = .live
        runtimeSurfaceFreedOutOfBandForTesting = false
    }
#endif

}
