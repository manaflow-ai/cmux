import AppKit
import SwiftUI

@available(macOS 15.4, *)
struct BrowserWebExtensionActionButton: View {
    let snapshot: BrowserWebExtensionActionSnapshot
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let performAction: (NSView?) -> Void

    @State private var anchorViewHolder = BrowserWebExtensionAnchorViewHolder()

    var body: some View {
        Button(action: {
#if DEBUG
            cmuxDebugLog(
                "browser.webext.action panel=\(panel.id.uuidString.prefix(5)) " +
                "name=\(snapshot.displayName)"
            )
#endif
            performAction(anchorViewHolder.view)
        }) {
            actionIcon
                .frame(width: hitSize, height: hitSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .background(BrowserWebExtensionAnchorViewReader(holder: anchorViewHolder))
        .disabled(!snapshot.isEnabled)
        .opacity(snapshot.isEnabled ? 1 : 0.45)
        .safeHelp(snapshot.displayName)
        .accessibilityIdentifier(snapshot.accessibilityIdentifier)
    }

    @ViewBuilder
    private var actionIcon: some View {
        ZStack(alignment: .topTrailing) {
            if let icon = snapshot.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconPointSize + 3, height: iconPointSize + 3)
            } else {
                CmuxSystemSymbolImage(
                    systemName: "puzzlepiece.extension",
                    pointSize: iconPointSize,
                    weight: .medium
                )
            }
            if !snapshot.badgeText.isEmpty {
                Text(snapshot.badgeText)
                    .font(.system(size: 8, weight: snapshot.hasUnreadBadgeText ? .bold : .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 10, maxWidth: 20, minHeight: 10)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .offset(x: 5, y: -4)
            }
        }
    }
}
