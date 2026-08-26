import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
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
        }
    }
}

private struct SessionIndexAgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.size == rhs.size
    }

    var body: some View {
        if let assetName = agent.assetName {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                source: .asset(name: assetName, bundle: .main),
                size: NSSize(width: size, height: size)
            ))
            .frame(width: size, height: size)
        } else {
            SessionIndexResolvedSystemSymbolImage(
                systemName: agent.systemImageName ?? "person.crop.circle",
                pointSize: max(size - 2, 10),
                size: size,
                weight: .regular,
                tintColor: .secondaryLabelColor,
                fallbackSource: .systemSymbol(
                    name: "person.crop.circle.fill",
                    accessibilityDescription: nil
                )
            )
        }
    }
}

private struct SessionIndexResolvedSystemSymbolImage: View {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    let systemName: String
    let pointSize: CGFloat
    let size: CGFloat
    let weight: NSFont.Weight
    let tintColor: NSColor
    let fallbackSource: CmuxResolvedIconSource?

    var body: some View {
        let rasterSize = GlobalFontMagnification.scaledSize(pointSize, percent: globalFontPercent)
        CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: nil),
            size: NSSize(width: rasterSize, height: rasterSize),
            tintColor: tintColor,
            symbolWeight: weight,
            fallbackSource: fallbackSource
        ))
        // Keep the magnified raster's own layout size, then center it in the
        // design-size slot. This mirrors `CmuxSystemSymbolImage(magnified:)`
        // and prevents the AppKit image view from scaling the larger bitmap
        // back down to the unscaled slot.
        .frame(width: rasterSize, height: rasterSize)
        .frame(width: size, height: size)
    }
}
