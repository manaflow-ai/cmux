import CmuxAgentChat
import SwiftUI

/// Snapshot-only recent-file list mounted above the right-sidebar file tree.
struct RecentAgentFilesSnapshotView: View {
    let files: [AgentRecentFile]
    let isLoading: Bool
    let onOpenFilePreview: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            fileButton(file)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebar.recentAgentFiles")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(x: 0.5)
                .accessibilityHidden(true)
            Text(String(localized: "rightSidebar.recentAgentFiles.title", defaultValue: "Recent Agent Files"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(
                        String(localized: "rightSidebar.recentAgentFiles.loading", defaultValue: "Loading recent agent files")
                    )
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
    }

    private var emptyState: some View {
        Text(
            isLoading
                ? String(
                    localized: "rightSidebar.recentAgentFiles.loading",
                    defaultValue: "Loading recent agent files"
                )
                : String(
                    localized: "rightSidebar.recentAgentFiles.empty",
                    defaultValue: "No recent Codex or Claude file changes"
                )
        )
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func fileButton(_ file: AgentRecentFile) -> some View {
        Button {
            onOpenFilePreview(file.path)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: file.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.fileName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(directoryLabel(for: file))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(file.agentKind.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(file.modifiedAt, style: .relative)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
        .accessibilityLabel(accessibilityLabel(for: file))
    }

    private func directoryLabel(for file: AgentRecentFile) -> String {
        guard !file.directoryPath.isEmpty else {
            return String(localized: "rightSidebar.recentAgentFiles.workspaceRoot", defaultValue: "Workspace root")
        }
        return file.directoryPath
    }

    private func accessibilityLabel(for file: AgentRecentFile) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "rightSidebar.recentAgentFiles.openAccessibility",
                defaultValue: "Open %@, changed by %@"
            ),
            file.fileName,
            file.agentKind.displayName
        )
    }
}
