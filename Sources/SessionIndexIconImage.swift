import AppKit
import SwiftUI

/// Renders a session agent mark through the shared appearance-resolved path.
struct AgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    var body: some View {
        let fallbackName = agent.systemImageName ?? "person.crop.circle"
        let sources: [CmuxResolvedIconSource]
        if let assetName = agent.assetName {
            sources = [
                .asset(name: assetName, bundle: .main),
                .systemSymbol(name: fallbackName, accessibilityDescription: nil),
            ]
        } else {
            sources = [.systemSymbol(name: fallbackName, accessibilityDescription: nil)]
        }

        CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
            sources: sources,
            size: NSSize(width: size, height: size),
            accessibilityDescription: agent.displayName
        ))
        .frame(width: size, height: size)
    }
}

/// Shared section icon renderer used by Vault rows, previews, and popovers.
struct SectionIconImage: View, Equatable {
    let icon: SectionIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .agent(let agent):
            AgentIconImage(agent: agent, size: size)
        case .folder:
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                sources: [
                    .systemSymbol(name: "folder", accessibilityDescription: nil),
                    .image(NSWorkspace.shared.icon(for: .folder)),
                ],
                size: NSSize(width: size, height: size),
                tintColor: .secondaryLabelColor
            ))
            .accessibilityHidden(true)
            .frame(width: size, height: size)
        }
    }
}
