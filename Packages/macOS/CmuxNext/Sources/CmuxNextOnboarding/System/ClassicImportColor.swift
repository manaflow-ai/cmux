import CmuxNextDesign

/// A classic workspace's color as cmux NEXT's palette names it.
public struct ClassicImportColor {
    public init() {}
    /// Classic saves `#RRGGBB`, which the sidebar does not draw: it becomes the palette color nearest its hue. A palette
    /// name passes through; anything else is nil (no color).
    public static func palette(_ saved: String) -> String? {
        let text = saved.trimmingCharacters(in: .whitespaces)
        if let named = GroupColor(rawValue: text.lowercased()) { return named.rawValue }
        let hex = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let rgb = UInt32(hex, radix: 16) else { return nil }
        return GroupColor.nearest(rgb: rgb).rawValue
    }
}
