#if DEBUG
import SwiftUI

/// Presents one shared workspace fixture using Meridian's native list metrics.
struct MeridianWorkspaceRow: View {
    let workspace: GalleryWorkspaceFixture

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {} label: {
            HStack(alignment: .top, spacing: 12) {
                MeridianStatusSymbol(state: workspace.state, font: .headline)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(workspace.name)
                            .font(.headline)
                            .foregroundStyle(theme.label)
                        Spacer(minLength: 8)
                        Text(workspace.elapsedText)
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryLabel)
                    }

                    Text(workspace.branch)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(1)

                    Text("\(workspace.agentName) · \(workspace.detailText)")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(2)

                    if let pendingQuestion = workspace.pendingQuestion {
                        Text(pendingQuestion)
                            .font(.subheadline)
                            .foregroundStyle(theme.needsYou)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MeridianPressButtonStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: workspace.pendingQuestion != nil) {
            if workspace.pendingQuestion != nil {
                Button(DesignGalleryFixtures.approvalActions[0]) {}
                    .tint(theme.accent)
            } else {
                Button("Open") {}
                    .tint(theme.accent)
            }
        }
        .contextMenu {
            Button("Open workspace") {}
            if workspace.pendingQuestion != nil {
                Button(DesignGalleryFixtures.approvalActions[0]) {}
            }
        }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
