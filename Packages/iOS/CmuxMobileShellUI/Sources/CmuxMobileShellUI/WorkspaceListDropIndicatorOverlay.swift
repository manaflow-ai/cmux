import CmuxMobileShellModel
import SwiftUI

struct WorkspaceListDropIndicatorOverlay: View {
    let target: MobileWorkspaceDropTarget?
    let rows: [MobileWorkspaceDropRowFrame]

    var body: some View {
        GeometryReader { proxy in
            if let indicator = target?.indicator {
                switch indicator.kind {
                case .insertLine:
                    let leading: CGFloat = indicator.indented ? 32 : 12
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, proxy.size.width - leading - 12), height: 2)
                        .position(
                            x: leading + max(0, proxy.size.width - leading - 12) / 2,
                            y: indicator.y
                        )
                case .highlightGroup(let groupID):
                    if let frame = rows.first(where: { $0.kind == .groupHeader(groupID) })?.frame {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
