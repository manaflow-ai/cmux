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
        // Sidebar row/group-header refresh is a hot path at workspace scale, so
        // blend the two normalized `#RRGGBB` colors with plain integer byte math
        // instead of allocating NSColor objects and converting color spaces per
        // refresh. Averaging the gamma-encoded sRGB bytes with integer division
        // matches the previous NSColor-based truncation.
        guard let lhs = sRGBBytes(lhsHex), let rhs = sRGBBytes(rhsHex) else {
            return nil
        }
        return hexString(
            red: (lhs.red + rhs.red) / 2,
            green: (lhs.green + rhs.green) / 2,
            blue: (lhs.blue + rhs.blue) / 2
        )
    }

    private static func sRGBBytes(_ hex: String) -> (red: Int, green: Int, blue: Int)? {
        let body = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    // Hex digit table hoisted to a stored static so the hot sidebar refresh
    // path doesn't re-allocate the array on every color-to-hex conversion.
    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private static func hexString(red: Int, green: Int, blue: Int) -> String {
        // Avoid String(format:) on this hot path: it is the byte-to-hex pattern
        // that caused unbounded memory growth in cmux PR #5347.
        func byteHex(_ value: Int) -> String {
            let clamped = max(0, min(255, value))
            return String([hexDigits[clamped >> 4], hexDigits[clamped & 0x0F]])
        }
        return "#" + byteHex(red) + byteHex(green) + byteHex(blue)
    }
}
