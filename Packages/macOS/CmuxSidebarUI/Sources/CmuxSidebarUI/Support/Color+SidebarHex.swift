public import SwiftUI
import Foundation

extension Color {
    /// Parses a 6-digit RGB hex string (with or without a leading `#`) into a
    /// `Color`, returning `nil` for any other length or non-hex content. Lifted
    /// byte-identically from the app target so sidebar-metadata rows render
    /// control-socket-supplied colors without depending on the app-target
    /// appearance support.
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }

    /// Resolves an optional 6-digit RGB hex string into a `Color`, returning
    /// `fallback` when the string is `nil` or not a valid 6-digit hex value.
    /// Drained byte-identically from the extension-sidebar icon renderer in the
    /// app target's `VerticalTabsSidebar` (a nil or invalid hex fell back to the
    /// caller-supplied color), so custom-sidebar provider icons resolve their
    /// foreground and background colors without an app-target helper.
    ///
    /// This deliberately parses with `Scanner.scanHexInt64` rather than
    /// reusing `Color(hex:)`'s `UInt64(_:radix:16)`. The two diverge inside the
    /// `count == 6` set: `Scanner` is a lenient prefix scanner (it accepts a
    /// leading `0x`/`0X`, embedded/leading/trailing whitespace, and any string
    /// whose leading run contains at least one hex digit, stopping at the first
    /// non-hex character), whereas `UInt64(_:radix:16)` requires the whole
    /// 6-character string to be hex but accepts a leading `+`. The original
    /// `extensionSidebarColor` used `Scanner`, so provider-supplied hex strings
    /// (free-form `String?` on `CmuxSidebarProviderIcon`) must resolve through
    /// `Scanner` to preserve which strings render a color versus the fallback.
    public static func sidebarHexColor(_ hex: String?, fallback: Color) -> Color {
        guard let hex else { return fallback }
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return fallback }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
