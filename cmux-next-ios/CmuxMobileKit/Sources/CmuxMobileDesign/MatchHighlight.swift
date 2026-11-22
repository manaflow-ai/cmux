#if os(iOS)
import SwiftUI
import UIKit

/// The mark behind a find or search match (Find in Chat, Search in File, terminal find, a linked
/// line in a file preview): the accent at a share, so it takes the person's accent and theme and
/// is never a raw yellow box (Leo, 2026-11-22: "THE YELLOW AND RED PLACEHOLDERS FOR SHIT / GO
/// FUCKING AUDIT THAT SHIT AND PREVENT THAT SHIT FROM FUCKING HAPPENING").
/// `scripts/cmux-next/check-ios-surface-colors.py` refuses raw yellow, red and orange.
public enum CmuxMobileMatchHighlight {
    /// The current match's share of the accent.
    public static let currentShare: CGFloat = 0.34
    /// Another match's share.
    public static let otherShare: CGFloat = 0.18
    /// A linked line's share (a file opened at a line).
    public static let lineShare: CGFloat = 0.14

    /// The accent at `share` of its own alpha.
    public static func fill(_ share: CGFloat) -> UIColor {
        UIColor { traits in
            let accent = UIColor.cmuxMobileAccent.resolvedColor(with: traits)
            var alpha: CGFloat = 1
            accent.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            return accent.withAlphaComponent(alpha * share)
        }
    }

    /// The current match's outline: the accent itself.
    public static var stroke: UIColor { .cmuxMobileAccent }
}

extension Color {
    /// ``CmuxMobileMatchHighlight/fill(_:)`` at the current match's share.
    public static var cmuxMobileMatch: Color { Color(uiColor: CmuxMobileMatchHighlight.fill(CmuxMobileMatchHighlight.currentShare)) }
    /// ``CmuxMobileMatchHighlight/fill(_:)`` at a linked line's share.
    public static var cmuxMobileMatchLine: Color { Color(uiColor: CmuxMobileMatchHighlight.fill(CmuxMobileMatchHighlight.lineShare)) }
}
#endif
