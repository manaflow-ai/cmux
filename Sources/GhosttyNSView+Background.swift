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


// MARK: - Surface and window background application
extension GhosttyNSView {
    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let usesBonsplitPaneBackdrop = Workspace.usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: backgroundColor,
            defaultBackgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: usesBonsplitPaneBackdrop
        )
        let color = fillPlan.hostLayerColor
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // GhosttySurfaceScrollView owns the panel background fill. Keeping this layer clear
            // avoids stacking multiple identical translucent backgrounds (which looks opaque).
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(
            color,
            clearsSharedWindowBackdrop: fillPlan.clearsSharedWindowBackdrop
        )
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(fillPlan.usesHostLayerFill ? color.hexString() : "transparent-host"):\(String(format: "%.3f", color.alphaComponent)):\(fillPlan.logBackdropLabel)"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                GhosttyApp.shared.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(fillPlan.logSource(hasSurfaceOverride: hasOverride)) override=\(overrideHex) default=\(defaultHex) sharedWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) bonsplitPaneBackdrop=\(usesBonsplitPaneBackdrop ? 1 : 0) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    // Theme/background application is window-local. During cross-window workspace
    // switches (e.g. jump-to-unread), the global active tab manager can lag behind.
    // Prefer the owning window's selected workspace when available.
    static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        let appDelegate = AppDelegate.shared
        let owningManager = tabId.flatMap { appDelegate?.tabManagerFor(tabId: $0) }
        let owningSelectedTabId = owningManager?.selectedTabId
        let activeSelectedTabId = owningManager == nil ? appDelegate?.tabManager?.selectedTabId : nil
        guard Self.shouldApplyWindowBackground(
            surfaceTabId: tabId,
            owningManagerExists: owningManager != nil,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ) else {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        let snapshot = WindowAppearanceSnapshot
            .currentFromUserDefaults(app: GhosttyApp.shared)
            .replacingTerminalBackgroundColor(backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(plan.hostingPhase.rawValue):\(color.hexString()):\(String(format: "%.3f", color.alphaComponent)):\(GhosttyApp.shared.defaultBackgroundBlur)"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                let source = hasOverride ? "surfaceOverride" : "defaultBackground"
                GhosttyApp.shared.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(source) override=\(overrideHex) default=\(defaultHex) phase=\(plan.hostingPhase.rawValue) transparent=\(plan.usesTransparentWindow) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent)) blur=\(GhosttyApp.shared.defaultBackgroundBlur)"
                )
            }
        }
    }

    func applySurfaceColorScheme(
        force: Bool = false,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let preferredColorScheme = preferredColorScheme
            ?? GhosttyApp.shared.effectiveTerminalColorSchemePreference
        let scheme = GhosttyApp.ghosttyRuntimeColorScheme(for: preferredColorScheme)
        if !force, appliedColorScheme == scheme {
            if GhosttyApp.shared.backgroundLogEnabled {
                let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
                GhosttyApp.shared.logBackground(
                    "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=false"
                )
            }
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        if GhosttyApp.shared.backgroundLogEnabled {
            let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
            GhosttyApp.shared.logBackground(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=true"
            )
        }
    }

}
