import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatBlockDetailSheetView: View {
    let detail: ChatBlockDetail
    let onOpenTerminal: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatArtifactLoader) private var artifactLoader

    init(detail: ChatBlockDetail, onOpenTerminal: (() -> Void)? = nil) {
        self.detail = detail
        self.onOpenTerminal = onOpenTerminal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = detail.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(detail.sections) { section in
                        ChatBlockDetailSectionView(section: section)
                    }
                    if artifactLoader.supportsArtifacts, !detail.artifactPaths.isEmpty {
                        ChatBlockDetailArtifactActions(paths: detail.artifactPaths)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(detail.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "chat.detail.done", defaultValue: "Done", bundle: .module)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ChatBlockDetailDoneButton")
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    openTerminalButton
                    copyAllButton
                }
                #else
                ToolbarItemGroup(placement: .confirmationAction) {
                    openTerminalButton
                    copyAllButton
                }
                #endif
            }
        }
        .accessibilityIdentifier("ChatBlockDetailSheet")
    }

    @ViewBuilder
    private var openTerminalButton: some View {
        if let onOpenTerminal {
            Button(action: onOpenTerminal) {
                Label(
                    String(
                        localized: "chat.terminal.open_in_terminal",
                        defaultValue: "Open in terminal",
                        bundle: .module
                    ),
                    systemImage: "terminal"
                )
            }
            .accessibilityIdentifier("ChatBlockDetailOpenTerminalButton")
        }
    }

    private var copyAllButton: some View {
        Button(action: copyAll) {
            Text(String(localized: "chat.detail.copy_all", defaultValue: "Copy All", bundle: .module))
                .fontWeight(.regular)
        }
        .disabled(detail.copyText.isEmpty)
        .accessibilityIdentifier("ChatBlockDetailCopyAllButton")
    }

    private func copyAll() {
        guard !detail.copyText.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = detail.copyText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.copyText, forType: .string)
        #endif
    }
}

private struct ChatBlockDetailArtifactActions: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "chat.artifact.actions.title", defaultValue: "Referenced Files", bundle: .module))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(deduplicatedPaths, id: \.self) { path in
                ChatBlockDetailArtifactActionRow(path: path)
            }
        }
    }

    private var deduplicatedPaths: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where !path.isEmpty && seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }
}

private struct ChatBlockDetailArtifactActionRow: View {
    let path: String

    @Environment(\.chatArtifactLoader) private var loader
    @State private var stat: ChatArtifactStat?
    @State private var selectedArtifact: ChatArtifactPathSelection?
    @State private var selectedFolder: ChatArtifactPathSelection?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if stat?.isDirectory == true {
                Button {
                    selectedFolder = ChatArtifactPathSelection(path: path)
                } label: {
                    Label(
                        String(localized: "chat.artifact.browse_folder", defaultValue: "Browse folder", bundle: .module),
                        systemImage: "folder"
                    )
                }
                .labelStyle(.iconOnly)
            } else {
                Button {
                    selectedArtifact = ChatArtifactPathSelection(path: path)
                } label: {
                    Label(
                        String(localized: "chat.artifact.view_file", defaultValue: "View file", bundle: .module),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .task(id: path) {
            stat = try? await loader.stat(path: path)
        }
        .sheet(item: $selectedArtifact) { selection in
            ChatArtifactViewerSheet(path: selection.path)
        }
        .sheet(item: $selectedFolder) { selection in
            ChatArtifactFolderView(path: selection.path)
        }
    }
}
