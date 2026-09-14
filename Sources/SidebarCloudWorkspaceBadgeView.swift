import SwiftUI

/// An immutable, fixed-width Cloud accessory; the row owns its accessibility label.
struct SidebarCloudWorkspaceBadgeView: View {
    let label: String?
    let pointSize: CGFloat
    let tint: Color

    var body: some View {
        if let label {
            CmuxSystemSymbolImage(magnified: "cloud", pointSize: pointSize, weight: .regular, tint: tint)
                .fixedSize()
                .safeHelp(label)
                .accessibilityHidden(true)
        }
    }
}
