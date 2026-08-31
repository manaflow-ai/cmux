import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Renders a session agent's branded asset or a resolved system-symbol fallback.
struct SessionIndexAgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.size == rhs.size
    }

    var body: some View {
        if let assetName = agent.assetName {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                source: .asset(name: assetName, bundle: .main),
                size: NSSize(width: size, height: size),
                fallbackSource: .systemSymbol(
                    name: "person.crop.circle.fill",
                    accessibilityDescription: nil
                ),
                fallbackTintColor: .secondaryLabelColor
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
