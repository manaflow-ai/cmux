import Foundation
import SwiftUI

/// Immutable Artifacts row with open, copy, reveal, and Vault-style drag actions.
struct ArtifactPaneRow: View {
    let snapshot: ArtifactPaneRowSnapshot
    let actions: ArtifactPaneRowActions

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)
                .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(snapshot.displayValue)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(snapshot.displayValue)
                    Spacer(minLength: 0)
                    if snapshot.record.occurrenceCount > 1 {
                        Text(String(
                            localized: "artifactsPane.repeatCount",
                            defaultValue: "×\(snapshot.record.occurrenceCount)"
                        ))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    }
                }

                if let title = snapshot.record.title,
                   !title.isEmpty,
                   title != snapshot.displayValue {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Text(snapshot.detail)
                    if let ownerTitle = snapshot.ownerTitle, !ownerTitle.isEmpty {
                        Text("·")
                        Text(ownerTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let snippet = snapshot.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if isHovered {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { actions.open(snapshot) }
        .contextMenu {
            Button(String(localized: "artifactsPane.action.open", defaultValue: "Open Artifact")) {
                actions.open(snapshot)
            }
            if snapshot.record.isURLLike {
                Button(String(localized: "linksPane.action.openBuiltIn", defaultValue: "Open in Built-in Browser")) {
                    actions.openBuiltIn(snapshot)
                }
                Button(String(localized: "linksPane.action.openDefault", defaultValue: "Open in Default Browser")) {
                    actions.openExternal(snapshot)
                }
                Button(String(localized: "linksPane.action.reveal", defaultValue: "Reveal in Pane")) {
                    actions.reveal(snapshot)
                }
            }
            Button(String(localized: "artifactsPane.action.copy", defaultValue: "Copy Artifact")) {
                actions.copy(snapshot)
            }
            if isRevealable && !snapshot.record.isURLLike {
                Button(String(localized: "artifactsPane.action.reveal", defaultValue: "Reveal in Finder")) {
                    actions.reveal(snapshot)
                }
            }
            Divider()
            Button(String(localized: "artifactsPane.action.remove", defaultValue: "Remove Artifact")) {
                actions.remove(snapshot)
            }
            Button(String(localized: "artifactsPane.action.clearAll", defaultValue: "Clear Workspace Artifacts"), action: actions.clearAll)
        }
        .onDrag { actions.dragProvider(snapshot) }
        .accessibilityIdentifier("ArtifactsPaneRow.\(snapshot.id.uuidString)")
    }

    private var iconTint: Color {
        switch snapshot.record.kind {
        case .url: .blue
        case .html: .orange
        case .image: .pink
        case .pdf: .red
        case .audio: .purple
        case .video: .indigo
        case .directory: .yellow
        case .browserDownload: .green
        case .code, .json: .mint
        case .file, .text, .manual, .generated: .secondary
        case .unknown: .secondary
        }
    }

    private var symbolName: String {
        switch snapshot.record.kind {
        case .url: "link"
        case .html: "doc.richtext"
        case .file, .text, .code, .json, .manual, .generated: "doc"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        case .directory: "folder"
        case .browserDownload: "arrow.down.circle"
        case .unknown: "questionmark.square"
        }
    }

    private var isRevealable: Bool {
        guard !isUnknownKind else { return false }
        switch snapshot.record.representation {
        case .managedFile, .directory:
            return true
        case .url(let value):
            return URL(string: value)?.isFileURL == true
        case .inlineText, .inlineHTML:
            return false
        }
    }

    private var isUnknownKind: Bool {
        if case .unknown = snapshot.record.kind { return true }
        return false
    }
}
