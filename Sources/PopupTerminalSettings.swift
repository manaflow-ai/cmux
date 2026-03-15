import Foundation
import SwiftUI

/// Persisted settings for the popup terminal.
enum PopupTerminalSettings {

    // MARK: - Enums

    enum Position: String, CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: String { rawValue }

        var label: String {
            switch self {
            case .top: return String(localized: "popupTerminal.position.top", defaultValue: "Pin to top")
            case .bottom: return String(localized: "popupTerminal.position.bottom", defaultValue: "Pin to bottom")
            case .left: return String(localized: "popupTerminal.position.left", defaultValue: "Pin to left")
            case .right: return String(localized: "popupTerminal.position.right", defaultValue: "Pin to right")
            }
        }

    }

    enum ScreenSelection: String, CaseIterable, Identifiable {
        case activeScreen
        case primaryScreen
        var id: String { rawValue }

        var label: String {
            switch self {
            case .activeScreen: return String(localized: "popupTerminal.screen.active", defaultValue: "Active Screen")
            case .primaryScreen: return String(localized: "popupTerminal.screen.primary", defaultValue: "Primary Screen")
            }
        }
    }

    // MARK: - UserDefaults keys

    static let enabledKey = "popupTerminal.enabled"
    static let positionKey = "popupTerminal.position"
    static let screenKey = "popupTerminal.screen"
    static let widthPercentKey = "popupTerminal.widthPercent"
    static let heightPercentKey = "popupTerminal.heightPercent"
    static let autoHideOnFocusLossKey = "popupTerminal.autoHideOnFocusLoss"
    static let animationDurationKey = "popupTerminal.animationDuration"

    // MARK: - Defaults

    static let defaultEnabled = true
    static let defaultPosition = Position.top
    static let defaultScreen = ScreenSelection.activeScreen
    static let defaultWidthPercent: Double = 100
    static let defaultHeightPercent: Double = 50
    static let defaultAutoHideOnFocusLoss = true
    static let defaultAnimationDuration: Double = 0.08

    // MARK: - Accessors

    static var isEnabled: Bool {
        get { isEnabled(defaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var position: Position {
        get { position(defaults: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: positionKey) }
    }

    static var screen: ScreenSelection {
        get { screen(defaults: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: screenKey) }
    }

    static var widthPercent: Double {
        get { widthPercent(defaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: widthPercentKey) }
    }

    static var heightPercent: Double {
        get { heightPercent(defaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: heightPercentKey) }
    }

    static var autoHideOnFocusLoss: Bool {
        get { autoHideOnFocusLoss(defaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: autoHideOnFocusLossKey) }
    }

    static var animationDuration: Double {
        get { animationDuration(defaults: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: animationDurationKey) }
    }

    // MARK: - Testable accessors

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func position(defaults: UserDefaults) -> Position {
        guard let raw = defaults.string(forKey: positionKey) else { return defaultPosition }
        return Position(rawValue: raw) ?? defaultPosition
    }

    static func screen(defaults: UserDefaults) -> ScreenSelection {
        guard let raw = defaults.string(forKey: screenKey) else { return defaultScreen }
        return ScreenSelection(rawValue: raw) ?? defaultScreen
    }

    static func widthPercent(defaults: UserDefaults) -> Double {
        let val = defaults.double(forKey: widthPercentKey)
        return val > 0 ? val : defaultWidthPercent
    }

    static func heightPercent(defaults: UserDefaults) -> Double {
        let val = defaults.double(forKey: heightPercentKey)
        return val > 0 ? val : defaultHeightPercent
    }

    static func autoHideOnFocusLoss(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoHideOnFocusLossKey) as? Bool ?? defaultAutoHideOnFocusLoss
    }

    static func animationDuration(defaults: UserDefaults) -> Double {
        let val = defaults.double(forKey: animationDurationKey)
        return val > 0 ? val : defaultAnimationDuration
    }

    // MARK: - Frame computation (pure, testable)

    static func computeTargetFrame(
        position: Position,
        widthPercent: Double,
        heightPercent: Double,
        visibleFrame: NSRect
    ) -> NSRect {
        let widthFraction = max(0.1, min(1.0, widthPercent / 100.0))
        let heightFraction = max(0.1, min(1.0, heightPercent / 100.0))

        let panelWidth = visibleFrame.width * widthFraction
        let panelHeight = visibleFrame.height * heightFraction

        switch position {
        case .top:
            let x = visibleFrame.minX + (visibleFrame.width - panelWidth) / 2
            let y = visibleFrame.maxY - panelHeight
            return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        case .bottom:
            let x = visibleFrame.minX + (visibleFrame.width - panelWidth) / 2
            let y = visibleFrame.minY
            return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        case .left:
            let x = visibleFrame.minX
            let y = visibleFrame.minY + (visibleFrame.height - panelHeight) / 2
            return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        case .right:
            let x = visibleFrame.maxX - panelWidth
            let y = visibleFrame.minY + (visibleFrame.height - panelHeight) / 2
            return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        }
    }

    static func computeOffscreenFrame(
        for targetFrame: NSRect,
        position: Position,
        screenFrame: NSRect
    ) -> NSRect {
        switch position {
        case .top:
            return targetFrame.offsetBy(dx: 0, dy: targetFrame.height)
        case .bottom:
            return targetFrame.offsetBy(dx: 0, dy: -targetFrame.height)
        case .left:
            return targetFrame.offsetBy(dx: -(targetFrame.maxX - screenFrame.minX), dy: 0)
        case .right:
            return targetFrame.offsetBy(dx: screenFrame.maxX - targetFrame.minX, dy: 0)
        }
    }
}
