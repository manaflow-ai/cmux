import Foundation
import CmuxTerminalCore

/// Config-derived values observed directly by persistent SwiftUI chrome.
struct TerminalConfigurationPresentationMetrics: Equatable {
    let terminalFontSize: CGFloat
    let surfaceTabBarFontSize: CGFloat
    let sidebarFontSize: CGFloat
    let chromeConfigurationIdentity:
        TerminalChromeConfigurationIdentity

    static func capture(
        configuration: GhosttyConfig,
        usesHostLayerBackground: Bool
    ) -> Self {
        return Self(
            terminalFontSize: configuration.fontSize,
            surfaceTabBarFontSize:
                configuration.surfaceTabBarFontSize,
            sidebarFontSize: configuration.sidebarFontSize,
            chromeConfigurationIdentity:
                TerminalChromeConfigurationIdentity(
                    configuration: configuration,
                    usesHostLayerBackground:
                        usesHostLayerBackground
                )
        )
    }

    func publishChanges(
        comparedTo previous: Self?
    ) {
        guard let previous else { return }
        let center = NotificationCenter.default
        if terminalFontSize != previous.terminalFontSize {
            center.post(
                name: .ghosttyTerminalFontSizeDidChange,
                object: nil
            )
        }
        if surfaceTabBarFontSize
            != previous.surfaceTabBarFontSize {
            center.post(
                name: .ghosttySurfaceTabBarFontSizeDidChange,
                object: nil
            )
        }
        if sidebarFontSize != previous.sidebarFontSize {
            center.post(
                name: .ghosttySidebarFontSizeDidChange,
                object: nil
            )
        }
        if chromeConfigurationIdentity
            != previous.chromeConfigurationIdentity {
            center.post(
                name: .ghosttyChromeConfigurationDidChange,
                object: nil
            )
        }
    }
}

extension Notification.Name {
    static let ghosttyTerminalFontSizeDidChange = Notification.Name(
        "ghosttyTerminalFontSizeDidChange"
    )
    static let ghosttySurfaceTabBarFontSizeDidChange = Notification.Name(
        "ghosttySurfaceTabBarFontSizeDidChange"
    )
    static let ghosttySidebarFontSizeDidChange = Notification.Name(
        "ghosttySidebarFontSizeDidChange"
    )
    static let ghosttyChromeConfigurationDidChange = Notification.Name(
        "ghosttyChromeConfigurationDidChange"
    )
}
