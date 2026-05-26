import Bonsplit
import SwiftUI

// MARK: - UI Scale Settings

enum UIScaleSettings {
    static let key = "uiScaleFactor"
    static let defaultValue: Double = 1.0
    static let minimumValue: Double = 0.5
    static let maximumValue: Double = 3.0
    static let stepIncrement: Double = 0.25

    static func resolvedScale(defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.object(forKey: key) as? Double ?? defaultValue
        return CGFloat(clampedValue(value))
    }

    static func clampedValue(_ value: Double) -> Double {
        min(maximumValue, max(minimumValue, value))
    }
}

// MARK: - Environment Key

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

// MARK: - Scaled Font View Modifier

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.uiScale) private var uiScale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design?

    func body(content: Content) -> some View {
        let scaledSize = size * uiScale
        if let design {
            content.font(.system(size: scaledSize, weight: weight, design: design))
        } else {
            content.font(.system(size: scaledSize, weight: weight))
        }
    }
}

extension View {
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

// MARK: - Environment Injection Modifier

/// ViewModifier that owns an @AppStorage and reactively injects the uiScale environment.
/// Use this instead of injecting from App.body, which doesn't re-evaluate on UserDefaults changes.
private struct UIScaleEnvironmentModifier: ViewModifier {
    @AppStorage(UIScaleSettings.key) private var scaleFactor = UIScaleSettings.defaultValue

    func body(content: Content) -> some View {
        let scale = CGFloat(UIScaleSettings.clampedValue(scaleFactor))
        content
            .environment(\.uiScale, scale)
            .environment(\.bonsplitUIScale, scale)
    }
}

extension View {
    func withUIScaleEnvironment() -> some View {
        modifier(UIScaleEnvironmentModifier())
    }
}

// MARK: - AppKit Helper

extension UIScaleSettings {
    /// For AppKit NSFont sites that cannot use SwiftUI environment.
    static func scaled(_ base: CGFloat, defaults: UserDefaults = .standard) -> CGFloat {
        base * resolvedScale(defaults: defaults)
    }
}
