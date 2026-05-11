import AppKit
import SwiftUI

enum UIScaleSettings {
    static let userDefaultsKey = "app.uiScale"
    static let jsonPath = "app.uiScale"
    static let didChangeNotification = Notification.Name("cmux.uiScaleDidChange")
    static let defaultValue = 1.0
    static let minimum = 0.7
    static let maximum = 2.0
    static let keyboardStep = 0.1

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func resolved(defaults: UserDefaults = .standard) -> Double {
        guard let number = defaults.object(forKey: userDefaultsKey) as? NSNumber else {
            return defaultValue
        }
        return clamped(number.doubleValue)
    }

    @discardableResult
    static func set(
        _ value: Double,
        defaults: UserDefaults = .standard,
        settingsFileStore: CmuxSettingsFileStore? = nil,
        persistToSettingsFile: Bool = true,
        notificationCenter: NotificationCenter = .default
    ) -> Double {
        let next = roundedForPersistence(clamped(value))
        defaults.set(next, forKey: userDefaultsKey)
        if persistToSettingsFile {
            do {
                try (settingsFileStore ?? KeyboardShortcutSettings.settingsFileStore).persistAppUIScale(next)
            } catch {
                NSLog("[UIScaleSettings] failed to persist %@: %@", jsonPath, String(describing: error))
            }
        }
        notificationCenter.post(name: didChangeNotification, object: nil, userInfo: ["value": next])
        return next
    }

    @discardableResult
    static func zoomIn() -> Double {
        set(resolved() + keyboardStep)
    }

    @discardableResult
    static func zoomOut() -> Double {
        set(resolved() - keyboardStep)
    }

    @discardableResult
    static func reset() -> Double {
        set(defaultValue)
    }

    static func scaled(_ value: CGFloat, by uiScaleFactor: Double) -> CGFloat {
        value * CGFloat(clamped(uiScaleFactor))
    }

    static func roundedForPersistence(_ value: Double) -> Double {
        (clamped(value) * 100).rounded() / 100
    }
}

private struct UIScaleFactorEnvironmentKey: EnvironmentKey {
    static let defaultValue = UIScaleSettings.defaultValue
}

extension EnvironmentValues {
    var uiScaleFactor: Double {
        get { self[UIScaleFactorEnvironmentKey.self] }
        set { self[UIScaleFactorEnvironmentKey.self] = UIScaleSettings.clamped(newValue) }
    }
}

private struct UIScaledFontModifier: ViewModifier {
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: UIScaleSettings.scaled(size, by: uiScaleFactor),
                weight: weight,
                design: design
            )
        )
    }
}

extension View {
    func cmuxFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(UIScaledFontModifier(size: size, weight: weight, design: design))
    }
}

extension NSFont {
    static func cmuxSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular, uiScaleFactor: Double) -> NSFont {
        systemFont(ofSize: UIScaleSettings.scaled(size, by: uiScaleFactor), weight: weight)
    }

    static func cmuxMonospacedSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular,
        uiScaleFactor: Double
    ) -> NSFont {
        monospacedSystemFont(ofSize: UIScaleSettings.scaled(size, by: uiScaleFactor), weight: weight)
    }
}
