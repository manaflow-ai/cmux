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


// MARK: - Default background resolution and application
extension GhosttyApp {
    func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    @discardableResult
    func setUsesHostLayerBackground(_ newValue: Bool, source: String) -> Bool {
        let previous = usesHostLayerBackground
        usesHostLayerBackground = newValue
        let hasChanged = previous != newValue
        if hasChanged, backgroundLogEnabled {
            logBackground(
                "terminal rendering mode changed source=\(source) usesHostLayerBackground=\(newValue) previous=\(previous)"
            )
        }
        return hasChanged
    }

    private func ghosttyColorValue(
        from config: ghostty_config_t,
        key: String,
        fallback: NSColor
    ) -> NSColor {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return fallback
        }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        forceNotify: Bool = false
    ) {
        guard let config else { return }

        let resolved = defaultBackgroundValues(from: config)
        applyDefaultBackground(
            color: resolved.backgroundColor,
            opacity: resolved.backgroundOpacity,
            backgroundBlur: resolved.backgroundBlur,
            foregroundColor: resolved.foregroundColor,
            cursorColor: resolved.cursorColor,
            cursorTextColor: resolved.cursorTextColor,
            selectionBackground: resolved.selectionBackground,
            selectionForeground: resolved.selectionForeground,
            source: source,
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private struct DefaultBackgroundValues {
        var backgroundColor: NSColor
        var backgroundOpacity: Double
        var backgroundBlur: GhosttyBackgroundBlur
        var foregroundColor: NSColor
        var cursorColor: NSColor
        var cursorTextColor: NSColor
        var selectionBackground: NSColor
        var selectionForeground: NSColor
    }

    private func defaultBackgroundValues(from config: ghostty_config_t?) -> DefaultBackgroundValues {
        let baseline = Self.fallbackAppearanceConfig
        guard let config else {
            return DefaultBackgroundValues(
                backgroundColor: baseline.backgroundColor,
                backgroundOpacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground
            )
        }

        let resolvedColor = ghosttyColorValue(from: config, key: "background", fallback: baseline.backgroundColor)
        let resolvedForeground = ghosttyColorValue(from: config, key: "foreground", fallback: baseline.foregroundColor)
        let resolvedCursor = ghosttyColorValue(from: config, key: "cursor-color", fallback: baseline.cursorColor)
        let resolvedCursorText = ghosttyColorValue(from: config, key: "cursor-text", fallback: baseline.cursorTextColor)
        let resolvedSelectionBackground = ghosttyColorValue(from: config, key: "selection-background", fallback: baseline.selectionBackground)
        let resolvedSelectionForeground = ghosttyColorValue(from: config, key: "selection-foreground", fallback: baseline.selectionForeground)
        var opacity = baseline.backgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        opacity = min(1.0, max(0.0, opacity))
        let backgroundBlur = defaultBackgroundBlurValue(from: config)
        return DefaultBackgroundValues(
            backgroundColor: resolvedColor,
            backgroundOpacity: opacity,
            backgroundBlur: backgroundBlur,
            foregroundColor: resolvedForeground,
            cursorColor: resolvedCursor,
            cursorTextColor: resolvedCursorText,
            selectionBackground: resolvedSelectionBackground,
            selectionForeground: resolvedSelectionForeground
        )
    }

    private func resolvedAppearanceValue<T>(
        parsedValue: T,
        baselineValue: T,
        unspecifiedFallbackValue: T,
        hasParsedDirective: Bool,
        hasDirective: Bool
    ) -> T {
        if hasParsedDirective {
            return parsedValue
        }
        if hasDirective {
            return baselineValue
        }
        return unspecifiedFallbackValue
    }

    func updateDefaultBackgroundFromResolvedGhosttyConfig(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        useOnDiskResolvedConfig: Bool = true,
        forceNotify: Bool = false
    ) {
        let baseline = defaultBackgroundValues(from: baselineConfig)
        guard useOnDiskResolvedConfig else {
            applyDefaultBackground(
                color: baseline.backgroundColor,
                opacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground,
                source: source,
                scope: scope,
                forceNotify: forceNotify
            )
            return
        }
        let resolved = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        let fallbackForUnspecified = Self.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance()
            ? defaultBackgroundValues(from: nil)
            : baseline
        applyDefaultBackground(
            color: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundColor,
                hasParsedDirective: resolved.hasParsedBackgroundColor,
                hasDirective: resolved.hasBackgroundColorDirective
            ),
            opacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective: resolved.hasParsedBackgroundOpacity,
                hasDirective: resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundBlur,
                hasParsedDirective: resolved.hasParsedBackgroundBlur,
                hasDirective: resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.foregroundColor,
                hasParsedDirective: resolved.hasParsedForegroundColor,
                hasDirective: resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorColor,
                hasParsedDirective: resolved.hasParsedCursorColor,
                hasDirective: resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorTextColor,
                hasParsedDirective: resolved.hasParsedCursorTextColor,
                hasDirective: resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionBackground,
                hasParsedDirective: resolved.hasParsedSelectionBackground,
                hasDirective: resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionForeground,
                hasParsedDirective: resolved.hasParsedSelectionForeground,
                hasDirective: resolved.hasSelectionForegroundDirective
            ),
            source: "\(source).resolvedGhosttyConfig",
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private func defaultBackgroundBlurValue(from config: ghostty_config_t) -> GhosttyBackgroundBlur {
        var value: Int16 = 0
        let key = "background-blur"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .disabled
        }
        return GhosttyBackgroundBlur(cValue: value)
    }

    func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        foregroundColor: NSColor? = nil,
        cursorColor: NSColor? = nil,
        cursorTextColor: NSColor? = nil,
        selectionBackground: NSColor? = nil,
        selectionForeground: NSColor? = nil,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope,
        forceNotify: Bool = false
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard Self.shouldApplyDefaultBackgroundUpdate(currentScope: previousScope, incomingScope: scope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        let previousBlur = defaultBackgroundBlur
        let previousForegroundHex = defaultForegroundColor.hexString()
        let previousCursorHex = defaultCursorColor.hexString()
        let previousCursorTextHex = defaultCursorTextColor.hexString()
        let previousSelectionBackgroundHex = defaultSelectionBackground.hexString()
        let previousSelectionForegroundHex = defaultSelectionForeground.hexString()
        let previousColorScheme = effectiveTerminalColorSchemePreference
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        defaultBackgroundBlur = backgroundBlur
        effectiveTerminalColorSchemePreference = Self.terminalRuntimeColorSchemePreference(
            forBackgroundColor: color
        )
        if let foregroundColor {
            defaultForegroundColor = foregroundColor
        }
        if let cursorColor {
            defaultCursorColor = cursorColor
        }
        if let cursorTextColor {
            defaultCursorTextColor = cursorTextColor
        }
        if let selectionBackground {
            defaultSelectionBackground = selectionBackground
        }
        if let selectionForeground {
            defaultSelectionForeground = selectionForeground
        }
        let hasChanged = forceNotify ||
            previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001 ||
            previousBlur != defaultBackgroundBlur ||
            previousForegroundHex != defaultForegroundColor.hexString() ||
            previousCursorHex != defaultCursorColor.hexString() ||
            previousCursorTextHex != defaultCursorTextColor.hexString() ||
            previousSelectionBackgroundHex != defaultSelectionBackground.hexString() ||
            previousSelectionForegroundHex != defaultSelectionForeground.hexString() ||
            previousColorScheme != effectiveTerminalColorSchemePreference
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default appearance updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousBg=\(previousHex) previousFg=\(previousForegroundHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) previousBlur=\(previousBlur) previousScheme=\(previousColorScheme) bg=\(defaultBackgroundColor.hexString()) fg=\(defaultForegroundColor.hexString()) cursor=\(defaultCursorColor.hexString()) cursorText=\(defaultCursorTextColor.hexString()) selectionBg=\(defaultSelectionBackground.hexString()) selectionFg=\(defaultSelectionForeground.hexString()) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur) scheme=\(effectiveTerminalColorSchemePreference) changed=\(hasChanged) forced=\(forceNotify)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source,
                foregroundColor: defaultForegroundColor,
                cursorColor: defaultCursorColor,
                cursorTextColor: defaultCursorTextColor,
                selectionBackground: defaultSelectionBackground,
                selectionForeground: defaultSelectionForeground
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        let snapshot = WindowAppearanceSnapshot.currentFromUserDefaults(app: self)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if backgroundLogEnabled {
            logBackground(
                "applied window backdrop phase=\(plan.hostingPhase.rawValue) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur)"
            )
        }
    }

    func applyWindowBlurIfNeeded(_ window: NSWindow) {
        guard let app = self.app else { return }
        // ghostty_set_window_background_blur reads background-blur and
        // background-opacity from the app config internally and calls
        // CGSSetWindowBackgroundBlurRadius, a compositor-level setter that is
        // idempotent.  It is a no-op when opacity >= 1.0 or blur is disabled,
        // so we can call it unconditionally whenever the window is transparent.
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if let raw = keyWindow?.identifier?.rawValue,
           raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
            return keyWindow
        }
        return NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        })
    }

}
