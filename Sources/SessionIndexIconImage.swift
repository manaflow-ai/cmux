import SwiftUI

/// Shared AppKit-backed icon view for Vault section headers and previews.
///
/// Every section presentation (the table, drag preview, and search popover)
/// uses this value so the affected icon family has one renderer and one
/// lifecycle owner.
struct SessionIndexSectionIconImage: View, Equatable {
    let icon: SectionIcon
    let size: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.icon == rhs.icon && lhs.size == rhs.size
    }

    var body: some View {
        switch icon {
        case .agent(let agent):
            SessionIndexAgentIconImage(agent: agent, size: size)
        case .folder:
            SessionIndexResolvedSystemSymbolImage(
                systemName: "folder",
                pointSize: max(size - 2, 10),
                size: size,
                weight: .regular,
                tintColor: .secondaryLabelColor,
                fallbackSource: .workspaceIcon(.folder)
            )
        case .day:
            SessionIndexResolvedSystemSymbolImage(
                systemName: "calendar",
                pointSize: max(size - 2, 10),
                size: size,
                weight: .regular,
                tintColor: .secondaryLabelColor,
                fallbackSource: .systemSymbol(
                    name: "calendar",
                    accessibilityDescription: nil
                )
            )
        case .search:
            SessionIndexResolvedSystemSymbolImage(
                systemName: "magnifyingglass",
                pointSize: max(size - 2, 10),
                size: size,
                weight: .regular,
                tintColor: .secondaryLabelColor,
                fallbackSource: .systemSymbol(
                    name: "magnifyingglass",
                    accessibilityDescription: nil
                )
            )
        }
    }
}
