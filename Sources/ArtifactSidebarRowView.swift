import CmuxArtifacts
import SwiftUI

/// Immutable project-file tree/search row.
struct ArtifactSidebarRowView: View {
    let snapshot: ArtifactSidebarRowSnapshot
    let actions: ArtifactSidebarRowActions

    var body: some View {
        HStack(spacing: 6) {
            disclosure
            ArtifactSidebarThumbnailView(
                fileURL: snapshot.fileURL,
                kind: snapshot.fileKind,
                isDirectory: snapshot.isDirectory
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detailText {
                    Text(detailText)
                        .cmuxFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Double(snapshot.depth) * 14 + 6)
        .padding(.trailing, 8)
        .frame(minHeight: 32)
        .contentShape(.rect)
        .onTapGesture {
            actions.activate(snapshot)
        }
        .contextMenu {
            contextMenu
        }
        .draggable(snapshot.fileURL)
        .accessibilityIdentifier("ArtifactSidebarRow.\(snapshot.id)")
    }

    @ViewBuilder
    private var disclosure: some View {
        if snapshot.isDirectory {
            Button {
                actions.toggleExpansion(snapshot)
            } label: {
                Image(systemName: snapshot.isExpanded ? "chevron.down" : "chevron.right")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isExpanded
                ? String(localized: "rightSidebar.artifacts.collapse", defaultValue: "Collapse folder")
                : String(localized: "rightSidebar.artifacts.expand", defaultValue: "Expand folder"))
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private var detailText: String? {
        if let snippet = snapshot.snippet { return snippet }
        return snapshot.depth == 0 && !snapshot.isDirectory ? snapshot.relativePath : nil
    }

    @ViewBuilder
    private var contextMenu: some View {
        if snapshot.isDirectory {
            Button(snapshot.isExpanded
                ? String(localized: "rightSidebar.artifacts.collapse", defaultValue: "Collapse folder")
                : String(localized: "rightSidebar.artifacts.expand", defaultValue: "Expand folder")) {
                actions.toggleExpansion(snapshot)
            }
        } else {
            Button(String(localized: "rightSidebar.artifacts.open", defaultValue: "Open File")) {
                actions.activate(snapshot)
            }
        }
        Divider()
        Button(String(localized: "rightSidebar.artifacts.reveal", defaultValue: "Reveal in Finder")) {
            actions.revealInFinder(snapshot)
        }
        Button(String(localized: "rightSidebar.artifacts.copyPath", defaultValue: "Copy Path")) {
            actions.copyPath(snapshot)
        }
        Button(String(localized: "rightSidebar.artifacts.copyReference", defaultValue: "Copy Reference")) {
            actions.copyReference(snapshot)
        }
    }
}
