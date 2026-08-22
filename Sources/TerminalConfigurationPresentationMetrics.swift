import Foundation

/// Config-derived values observed directly by persistent SwiftUI chrome.
struct TerminalConfigurationPresentationMetrics: Equatable {
    let terminalFontSize: CGFloat
    let surfaceTabBarFontSize: CGFloat
    let sidebarFontSize: CGFloat

    static func capture(
        magnificationPercent: Int
    ) -> Self {
        let config = GhosttyConfig.loadForCmux(
            useCache: false,
            globalFontMagnificationPercent:
                magnificationPercent
        )
        return Self(
            terminalFontSize: config.fontSize,
            surfaceTabBarFontSize:
                config.surfaceTabBarFontSize,
            sidebarFontSize: config.sidebarFontSize
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
}
