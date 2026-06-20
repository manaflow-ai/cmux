import SwiftUI

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
}
