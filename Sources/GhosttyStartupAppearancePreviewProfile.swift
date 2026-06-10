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


// MARK: - Startup appearance preview profile
enum GhosttyStartupAppearancePreviewProfile: String, CaseIterable, Identifiable {
    case realUserConfig
    case freshInstall
    case userThemePair
    case userSingleTheme
    case userExplicitColors

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.title",
                defaultValue: "Real User Config"
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.title",
                defaultValue: "Fresh Install"
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.title",
                defaultValue: "User Light/Dark Theme"
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.title",
                defaultValue: "User Single Theme"
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.title",
                defaultValue: "User Explicit Colors"
            )
        }
    }

    var detail: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.detail",
                defaultValue: "Loads your actual Ghostty and cmux config files."
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.detail",
                defaultValue: "No user theme or terminal colors, so cmux applies its managed default colors."
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.detail",
                defaultValue: "Simulates a user with an explicit light/dark Ghostty theme."
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.detail",
                defaultValue: "Simulates a user with one Ghostty theme applied in both appearances."
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.detail",
                defaultValue: "Simulates a user with direct terminal color settings and no theme."
            )
        }
    }

    var loadsRealUserConfig: Bool {
        self == .realUserConfig
    }

    func previewConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference()
    ) -> String? {
        switch self {
        case .realUserConfig:
            return nil
        case .freshInstall:
            return GhosttyConfig.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme
            )
        case .userThemePair:
            return "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        case .userSingleTheme:
            return "theme = Catppuccin Mocha"
        case .userExplicitColors:
            return """
            background = #101820
            foreground = #F4F7F7
            cursor-color = #FEE715
            cursor-text = #101820
            selection-background = #28536B
            selection-foreground = #F4F7F7
            palette = 0=#101820
            palette = 1=#C14953
            palette = 2=#47A025
            palette = 3=#D9A441
            palette = 4=#2E86AB
            palette = 5=#9B5DE5
            palette = 6=#00A6A6
            palette = 7=#D6D6D6
            palette = 8=#5C6672
            palette = 9=#FF6B6B
            palette = 10=#7BD88F
            palette = 11=#FFD166
            palette = 12=#54C6EB
            palette = 13=#C77DFF
            palette = 14=#4ECDC4
            palette = 15=#FFFFFF
            """
        }
    }
}

enum GhosttyStartupAppearancePreviewState {
    static var profile: GhosttyStartupAppearancePreviewProfile = .realUserConfig
}

