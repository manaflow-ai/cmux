import AppKit
import SwiftUI

/// Neutral icon treatment shared by every non-branded Vault glyph.
///
/// Keeping the tint and symbol weight in one place prevents computed day
/// headers from drifting away from folder/agent fallback icons as each path
/// evolves independently.
enum SessionIndexIconStyle {
    static let neutralTintColor: NSColor = .secondaryLabelColor
    static let symbolWeight: NSFont.Weight = .regular

    static func pointSize(for slotSize: CGFloat) -> CGFloat {
        max(slotSize - 2, 10)
    }
}

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
                pointSize: SessionIndexIconStyle.pointSize(for: size),
                size: size,
                weight: SessionIndexIconStyle.symbolWeight,
                tintColor: SessionIndexIconStyle.neutralTintColor,
                fallbackSource: .workspaceIcon(.folder)
            )
        case .day:
            SessionIndexResolvedSystemSymbolImage(
                systemName: "calendar",
                pointSize: SessionIndexIconStyle.pointSize(for: size),
                size: size,
                weight: SessionIndexIconStyle.symbolWeight,
                tintColor: SessionIndexIconStyle.neutralTintColor,
                fallbackSource: .systemSymbol(
                    name: "calendar",
                    accessibilityDescription: nil
                )
            )
        case .search:
            SessionIndexResolvedSystemSymbolImage(
                systemName: "magnifyingglass",
                pointSize: SessionIndexIconStyle.pointSize(for: size),
                size: size,
                weight: SessionIndexIconStyle.symbolWeight,
                tintColor: SessionIndexIconStyle.neutralTintColor,
                fallbackSource: .systemSymbol(
                    name: "magnifyingglass",
                    accessibilityDescription: nil
                )
            )
        }
    }
}
