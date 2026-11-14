#if os(iOS)
import CmuxTheme
import SwiftUI

/// The phone's neutral adaptation of the shared transient material.
///
/// This never reads the paired Mac's palette. Native menus keep their system
/// presentation; app-owned floating surfaces use regular Liquid Glass and
/// sheets use the system regular material. Shape and motion belong to callers.
public struct CmuxMobileTransientMaterial: Sendable, Equatable {
    /// The shipped material. A nil material at a call site preserves held chat UI.
    public static let standard = Self(strength: 1)

    private let strength: Double

    #if DEBUG
    /// Gallery-only lower veil for comparison with the selected standard.
    public static let quieter = Self(strength: 0.75)
    /// Gallery-only higher veil; never a production default.
    public static let denser = Self(strength: 1.25)
    #endif

    /// The one neutral veil used by floating glass and sheet presentation.
    func tint(in scheme: ColorScheme) -> Color {
        let token = TransientMaterial.standard
        let neutral = scheme == .dark ? token.neutralDark : token.neutralLight
        let alpha = scheme == .dark ? token.darkVeilAlpha : token.lightVeilAlpha
        return Color(white: neutral).opacity(min(1, alpha * token.nativeTintStrength * strength))
    }
}
#endif
