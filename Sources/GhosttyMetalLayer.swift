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


// MARK: - Metal layer
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

