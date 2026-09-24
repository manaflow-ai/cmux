import SwiftUI

/// Gives both levels of the account menu the same compact row rhythm.
struct SidebarAccountMenuButtonStyle: ButtonStyle {
    static let rowHeight: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}
