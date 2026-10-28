// The paths, defaults, ranges and choices are generated from
// schemas/settings/source/color-transition.json (Schema/SettingsSchema+ColorTransition.generated.swift);
// this file only parses.
public import CmuxNextDesignTokens

/// `appearance.colorTransition.*` in cmux.json (cx-3rf4z): how theme and color changes animate.
/// Absent keys take their defaults; a bad value takes its default plus a diagnostic.
public nonisolated struct ColorTransitionSetting: Sendable, Equatable {
    public var transition: ColorTransition

    public init(transition: ColorTransition = Self.defaultTransition) {
        self.transition = transition
    }

    /// The transition with every key at its default.
    public static var defaultTransition: ColorTransition {
        ColorTransition(enabled: enabledDefault, duration: durationDefault / 1000,
                        curve: curve(curveDefault, springResponse: springResponseDefault, springDamping: springDampingDefault,
                                     bezier: (bezierX1Default, bezierY1Default, bezierX2Default, bezierY2Default)),
                        space: space(colorSpaceDefault), reduceMotion: reduceMotion(reduceMotionDefault))
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        guard var reader = ConfigFieldReader(root, at: ["appearance", "colorTransition"], diagnostics: &diagnostics) else { return Self() }
        let enabled = reader.bool("enabled") ?? enabledDefault
        let duration = reader.number("duration", range: durationRange) ?? durationDefault
        let curveChoice = reader.choice("curve", ColorTransitionCurveSetting.self) ?? curveDefault
        let response = reader.number("springResponse", range: springResponseRange) ?? springResponseDefault
        let damping = reader.number("springDamping", range: springDampingRange) ?? springDampingDefault
        let bezier = (reader.number("bezierX1", range: bezierX1Range) ?? bezierX1Default,
                      reader.number("bezierY1", range: bezierY1Range) ?? bezierY1Default,
                      reader.number("bezierX2", range: bezierX2Range) ?? bezierX2Default,
                      reader.number("bezierY2", range: bezierY2Range) ?? bezierY2Default)
        let spaceChoice = reader.choice("colorSpace", ColorTransitionSpaceSetting.self) ?? colorSpaceDefault
        let reduceChoice = reader.choice("reduceMotion", ColorTransitionReduceMotionSetting.self) ?? reduceMotionDefault
        diagnostics += reader.diagnostics
        return Self(transition: ColorTransition(
            enabled: enabled, duration: duration / 1000,
            curve: curve(curveChoice, springResponse: response, springDamping: damping, bezier: bezier),
            space: space(spaceChoice), reduceMotion: reduceMotion(reduceChoice)))
    }

    static func curve(_ choice: ColorTransitionCurveSetting, springResponse: Double, springDamping: Double,
                      bezier: (Double, Double, Double, Double)) -> ColorTransition.Curve {
        switch choice {
        case .easeOut: .easeOut
        case .easeInOut: .easeInOut
        case .linear: .linear
        case .spring: .spring(SpringParameters(response: springResponse, dampingFraction: springDamping))
        case .cubicBezier: .cubicBezier(bezier.0, bezier.1, bezier.2, bezier.3)
        }
    }

    static func space(_ choice: ColorTransitionSpaceSetting) -> ThemeColorSpace {
        switch choice {
        case .oklab: .oklab
        case .srgb: .srgb
        }
    }

    static func reduceMotion(_ choice: ColorTransitionReduceMotionSetting) -> ColorTransition.ReduceMotion {
        switch choice {
        case .crossfade: .crossfade
        case .instant: .instant
        case .full: .full
        }
    }
}
