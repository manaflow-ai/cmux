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


// MARK: - Window glass policy
#if os(macOS)
func cmuxShouldApplyWindowGlass(
    sidebarBlendMode: String,
    bgGlassEnabled: Bool,
    glassEffectAvailable _: Bool
) -> Bool {
    // Native NSGlassEffectView vs NSVisualEffectView fallback is chosen inside
    // WindowGlassEffect.apply. User settings alone decide whether glass is on.
    sidebarBlendMode == "behindWindow" && bgGlassEnabled
}

func cmuxShouldUseTransparentBackgroundWindow() -> Bool {
    let defaults = UserDefaults.standard
    let sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    let bgGlassEnabled = defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false
    return cmuxShouldApplyWindowGlass(
        sidebarBlendMode: sidebarBlendMode,
        bgGlassEnabled: bgGlassEnabled,
        glassEffectAvailable: WindowGlassEffect.isAvailable
    )
}

func cmuxShouldUseClearWindowBackground(for opacity: Double, usesGhosttyGlassStyle: Bool = false) -> Bool {
    cmuxShouldUseTransparentBackgroundWindow() || usesGhosttyGlassStyle || opacity < 0.999
}

@_silgen_name("CGSDefaultConnectionForThread")
private func cmuxCGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func cmuxCGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: UInt,
    _ radius: Int32
) -> Int32

func cmuxResetCompositorBackgroundBlur(on window: NSWindow) {
    _ = cmuxCGSSetWindowBackgroundBlurRadius(
        cmuxCGSDefaultConnectionForThread(),
        UInt(window.windowNumber),
        0
    )
}

func cmuxTransparentWindowBaseColor() -> NSColor {
    // A tiny non-zero alpha matches Ghostty's window compositing behavior on macOS and
    // avoids visual artifacts that can happen with a fully clear window background.
    NSColor.white.withAlphaComponent(0.001)
}

// `flagsChanged` is used for both modifier presses and releases on macOS.
// Returning the wrong edge leaves Ghostty with a phantom held modifier until
// a later focus loss flushes release events into the PTY.
func cmuxGhosttyModifierActionForFlagsChanged(
    keyCode: UInt16,
    modifierFlagsRawValue: UInt
) -> ghostty_input_action_e? {
    let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    let modifierActive: Bool
    switch keyCode {
    case 0x39:
        modifierActive = flags.contains(.capsLock)
    case 0x38, 0x3C:
        modifierActive = flags.contains(.shift)
    case 0x3B, 0x3E:
        modifierActive = flags.contains(.control)
    case 0x3A, 0x3D:
        modifierActive = flags.contains(.option)
    case 0x37, 0x36:
        modifierActive = flags.contains(.command)
    default:
        return nil
    }

    guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

    let sidePressed: Bool
    switch keyCode {
    case 0x38:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
    case 0x3C:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
    case 0x3B:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
    case 0x3E:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
    case 0x3A:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELALTKEYMASK) != 0
    case 0x3D:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERALTKEYMASK) != 0
    case 0x37:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
    case 0x36:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
    default:
        sidePressed = true
    }

    return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
}
#endif

