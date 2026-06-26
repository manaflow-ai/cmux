import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation

extension WorkspaceTabColorSettings {
    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        if let normalized = normalizedHex(raw) {
            return normalized
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolvedPaletteMap(defaults: defaults)
            .first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?
            .value
    }

    static func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }
}

struct WorkspaceStateColorResolver: Equatable {
    let isEnabled: Bool
    let mode: WorkspaceStateColorMode
    let colorHexByState: [String: String]

    func resolvedColorHex(
        manualColorHex: String?,
        agentLifecycleState: AgentHibernationLifecycleState
    ) -> String? {
        let manualColor = manualColorHex.flatMap(Self.normalizedColorHex)
        guard isEnabled else { return manualColor }

        let stateColor = colorHexByState[agentLifecycleState.rawValue].flatMap(Self.normalizedColorHex)
        switch mode {
        case .replace:
            return stateColor
        case .blend:
            guard let stateColor else { return manualColor }
            guard let manualColor else { return stateColor }
            return Self.blendedColorHex(manualColor, stateColor) ?? stateColor
        }
    }

    private static func normalizedColorHex(_ raw: String) -> String? {
        WorkspaceTabColorSettings.resolvedColorHex(raw)
    }

    private static func blendedColorHex(_ lhsHex: String, _ rhsHex: String) -> String? {
        guard let lhs = NSColor(hex: lhsHex)?.usingColorSpace(.sRGB),
              let rhs = NSColor(hex: rhsHex)?.usingColorSpace(.sRGB) else {
            return nil
        }

        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        lhs.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha)
        rhs.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha)

        return NSColor(
            srgbRed: (lhsRed + rhsRed) / 2,
            green: (lhsGreen + rhsGreen) / 2,
            blue: (lhsBlue + rhsBlue) / 2,
            alpha: 1
        ).hexString()
    }
}
