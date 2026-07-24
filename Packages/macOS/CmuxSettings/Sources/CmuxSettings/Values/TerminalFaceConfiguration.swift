import Foundation

/// Controls when the terminal-face animation clock advances.
public enum TerminalFaceAnimation: String, Codable, CaseIterable, Sendable, SettingCodable {
    case off
    case whenVisible
    case always
}

/// Complete visual and lifecycle configuration for the terminal face.
///
/// The same value is used for the global default and optional workspace or
/// terminal overrides, which keeps scope resolution deterministic.
public struct TerminalFaceConfiguration: Codable, Sendable, Equatable, Hashable {
    public var enabled: Bool
    public var reactsToAgents: Bool
    public var animation: TerminalFaceAnimation
    public var opacity: Double
    public var glow: Double
    public var scale: Double
    public var horizontalPosition: Double
    public var verticalPosition: Double
    public var characterDensity: Double
    public var motion: Double
    public var gaze: Double
    public var idleColor: String
    public var thinkingColor: String
    public var workingColor: String
    public var doneColor: String
    public var needsInputColor: String
    public var errorColor: String

    public static let `default` = TerminalFaceConfiguration(
        enabled: false,
        reactsToAgents: true,
        animation: .whenVisible,
        opacity: 0.30,
        glow: 0.45,
        scale: 0.62,
        horizontalPosition: 0.50,
        verticalPosition: 0.52,
        characterDensity: 0.50,
        motion: 0.55,
        gaze: 0.65,
        idleColor: "#5CE0C9",
        thinkingColor: "#F0C24A",
        workingColor: "#3D70E0",
        doneColor: "#8CD447",
        needsInputColor: "#D984E8",
        errorColor: "#F25C6B"
    )

    public init(
        enabled: Bool,
        reactsToAgents: Bool,
        animation: TerminalFaceAnimation,
        opacity: Double,
        glow: Double,
        scale: Double,
        horizontalPosition: Double,
        verticalPosition: Double,
        characterDensity: Double,
        motion: Double,
        gaze: Double,
        idleColor: String,
        thinkingColor: String,
        workingColor: String,
        doneColor: String,
        needsInputColor: String,
        errorColor: String
    ) {
        self.enabled = enabled
        self.reactsToAgents = reactsToAgents
        self.animation = animation
        self.opacity = opacity
        self.glow = glow
        self.scale = scale
        self.horizontalPosition = horizontalPosition
        self.verticalPosition = verticalPosition
        self.characterDensity = characterDensity
        self.motion = motion
        self.gaze = gaze
        self.idleColor = idleColor
        self.thinkingColor = thinkingColor
        self.workingColor = workingColor
        self.doneColor = doneColor
        self.needsInputColor = needsInputColor
        self.errorColor = errorColor
        sanitize()
    }

    public mutating func sanitize() {
        opacity = opacity.clamped(to: 0...1)
        glow = glow.clamped(to: 0...1)
        scale = scale.clamped(to: 0.25...1)
        horizontalPosition = horizontalPosition.clamped(to: 0...1)
        verticalPosition = verticalPosition.clamped(to: 0...1)
        characterDensity = characterDensity.clamped(to: 0...1)
        motion = motion.clamped(to: 0...1)
        gaze = gaze.clamped(to: 0...1)
        idleColor = Self.validatedColor(idleColor, fallback: Self.defaultColor("#5CE0C9"))
        thinkingColor = Self.validatedColor(thinkingColor, fallback: Self.defaultColor("#F0C24A"))
        workingColor = Self.validatedColor(workingColor, fallback: Self.defaultColor("#3D70E0"))
        doneColor = Self.validatedColor(doneColor, fallback: Self.defaultColor("#8CD447"))
        needsInputColor = Self.validatedColor(needsInputColor, fallback: Self.defaultColor("#D984E8"))
        errorColor = Self.validatedColor(errorColor, fallback: Self.defaultColor("#F25C6B"))
    }

    private static func validatedColor(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ $0.isHexDigit }) else { return fallback }
        return value
    }

    private static func defaultColor(_ value: String) -> String { value }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

extension TerminalFaceConfiguration: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? { decode(raw) }
    public func encodeForUserDefaults() -> Any { encode() }
    public static func decodeFromJSON(_ raw: Any?) -> Self? { decode(raw) }
    public func encodeForJSON() -> Any { encode() }

    private static func decode(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        value.sanitize()
        return value
    }

    private func encode() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }
}
