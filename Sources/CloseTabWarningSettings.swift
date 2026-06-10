import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Close Tab Confirmation Settings
enum CloseTabWarningSettings {
    static let warnBeforeClosingTabKey = "warnBeforeClosingTabShortcut"
    static let defaultWarnBeforeClosingTab = true
    static let warnBeforeClosingTabXButtonKey = "warnBeforeClosingTabXButton"
    static let defaultWarnBeforeClosingTabXButton = false
    static let hideTabCloseButtonKey = "hideTabCloseButton"
    static let defaultHideTabCloseButton = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeClosingTabKey) == nil {
            return defaultWarnBeforeClosingTab
        }
        return defaults.bool(forKey: warnBeforeClosingTabKey)
    }

    static func warnsBeforeClosingTabXButton(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: warnBeforeClosingTabXButtonKey) == nil {
            return defaultWarnBeforeClosingTabXButton
        }
        return defaults.bool(forKey: warnBeforeClosingTabXButtonKey)
    }

    static func hidesTabCloseButton(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hideTabCloseButtonKey) == nil {
            return defaultHideTabCloseButton
        }
        return defaults.bool(forKey: hideTabCloseButtonKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: warnBeforeClosingTabKey)
    }
}

enum CloseTabConfirmationPolicy {
    enum Source: Equatable {
        case shortcut
        case tabCloseButton
    }

    enum Decision: Equatable {
        case closeImmediately
        case confirmBeforeClosing
    }

    static func decision(
        requiresConfirmation: Bool,
        source: Source,
        defaults: UserDefaults = .standard
    ) -> Decision {
        let shouldConfirm: Bool
        switch source {
        case .shortcut:
            shouldConfirm = requiresConfirmation && CloseTabWarningSettings.isEnabled(defaults: defaults)
        case .tabCloseButton:
            shouldConfirm = CloseTabWarningSettings.warnsBeforeClosingTabXButton(defaults: defaults)
                || (requiresConfirmation && CloseTabWarningSettings.isEnabled(defaults: defaults))
        }

        guard shouldConfirm else {
            return .closeImmediately
        }
        return .confirmBeforeClosing
    }

    static func shouldConfirm(
        requiresConfirmation: Bool,
        source: Source,
        defaults: UserDefaults = .standard
    ) -> Bool {
        decision(
            requiresConfirmation: requiresConfirmation,
            source: source,
            defaults: defaults
        ) == .confirmBeforeClosing
    }
}

