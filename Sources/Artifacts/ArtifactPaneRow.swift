import SwiftUI

/// Immutable Artifacts row with open, copy, reveal, and Vault-style drag actions.
struct ArtifactPaneRow: View {
    let snapshot: ArtifactPaneRowSnapshot
    let actions: ArtifactPaneRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(snapshot.displayValue)
                    .font(.system(size: 13))
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
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
            Text(snapshot.detail)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.open(snapshot) }
        .contextMenu {
            Button(String(localized: "artifactsPane.action.open", defaultValue: "Open Artifact")) {
                actions.open(snapshot)
            }
            Button(String(localized: "artifactsPane.action.copy", defaultValue: "Copy Artifact")) {
                actions.copy(snapshot)
            }
            if isRevealable {
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
        switch snapshot.record.kind {
        case .unknown:
            false
        default:
            snapshot.record.kind.isFileBacked
        }
    }
}
