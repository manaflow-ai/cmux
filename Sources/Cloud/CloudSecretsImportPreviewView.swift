import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What an import will do, by name, before anything is stored: new,
/// replaces a stored value, unchanged, or skipped with the reason. Values
/// are never listed. Import is the only commit; Esc cancels.
struct CloudSecretsImportPreviewView: View {
    @Bindable var model: CloudSecretsSheetModel
    let draft: CloudSecretsSheetModel.ImportDraft

    /// Past this many rows the preview's list scrolls, so its title, summary
    /// and Import button fit the sheet's fixed body without scrolling it.
    private static let maxUnscrolledRows = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    format: String(localized: "cloudSecrets.import.title", defaultValue: "Import from %@"),
                    draft.sourceName
                ))
                .cmuxFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                Text(String(
                    format: String(localized: "cloudSecrets.import.scope", defaultValue: "Into %1$@ · %2$@"),
                    CloudSecretsSheetPresentation.scopeDescription(draft.scope, machineLabels: model.machineLabels),
                    CloudSecretsSheetPresentation.importSummary(draft.preview)
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            rows

            if let error = draft.error {
                CloudSecretsMessageBox(text: error, isError: true)
            }

            HStack(spacing: 8) {
                Text(String(localized: "cloudSecrets.import.valuesHidden", defaultValue: "Values stay hidden. Only names are shown."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                Spacer()
                if draft.isCommitting {
                    ProgressView().controlSize(.small)
                }
                Button(String(localized: "cloudSecrets.import.cancel", defaultValue: "Cancel")) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CloudSecretsImport.cancel")
                Button(String(localized: "cloudSecrets.import.commit", defaultValue: "Import")) {
                    Task { await model.commitImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.preview.canCommit || draft.isCommitting)
                .help(draft.preview.canCommit
                    ? ""
                    : String(localized: "cloudSecrets.import.nothing", defaultValue: "Every variable is already stored with the same value, or was skipped."))
                .accessibilityIdentifier("CloudSecretsImport.commit")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudSecretsImport")
    }

    @ViewBuilder
    private var rows: some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(draft.preview.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 12) }
                CloudSecretsImportRow(row: row)
            }
        }
        Group {
            if draft.preview.rows.count > Self.maxUnscrolledRows {
                ScrollView { list }
                    .frame(height: CGFloat(Self.maxUnscrolledRows) * 32)
            } else {
                list
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CloudSecretsImportRow: View {
    let row: CloudSecretsSheetPresentation.ImportRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(row.name)
                .cmuxFont(size: 12, weight: .medium, design: .monospaced)
                .foregroundStyle(row.problem == nil && row.kind != .unchanged ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(row.problem ?? CloudSecretsSheetPresentation.importKindTitle(row.kind))
                .cmuxFont(size: 11)
                .foregroundStyle(detailStyle)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 300, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("CloudSecretsImport.row.\(row.name)")
    }

    /// A skipped line is expected and reads as quiet secondary text; only a
    /// name that needs renaming is amber. Nothing here is an error.
    private var detailStyle: AnyShapeStyle {
        if row.needsAttention { return AnyShapeStyle(Color.orange) }
        if row.isSkipped { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        return AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    private var symbol: String {
        if row.needsAttention { return "exclamationmark.triangle.fill" }
        if row.isSkipped { return "minus" }
        switch row.kind {
        case .added: return "plus"
        case .updated: return "arrow.triangle.2.circlepath"
        case .unchanged: return "equal"
        case .removed: return "minus"
        }
    }

    private var tint: Color {
        if row.needsAttention { return .orange }
        if row.isSkipped { return .secondary }
        switch row.kind {
        case .added: return .green
        case .updated: return .orange
        case .unchanged, .removed: return .secondary
        }
    }
}

/// Reading `.env` text from a chosen file, the clipboard, or a drop. Files
/// over 256 KB are refused before reading; nothing is kept after parsing.
/// lint:allow namespace-type: stateless AppKit entry points (open panel, clipboard, drop) for the sheet.
@MainActor
enum CloudSecretsDotenvFile {
    static let maxBytes = 256 * 1_024

    /// Opens a panel that shows dotfiles, then previews the chosen file.
    static func choose(into model: CloudSecretsSheetModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "cloudSecrets.import.panel.title", defaultValue: "Import .env File")
        panel.prompt = String(localized: "cloudSecrets.import.panel.prompt", defaultValue: "Review")
        panel.message = String(localized: "cloudSecrets.import.panel.message", defaultValue: "Choose a .env file. You can review its variables before anything is stored.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            load(url) { text, name in
                Task { await model.beginImport(text: text, sourceName: name, source: .dotenv(name)) }
            } failure: { model.showActionError($0) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// Previews `KEY=VALUE` lines from the clipboard.
    static func paste(into model: CloudSecretsSheetModel) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            model.showActionError(String(localized: "cloudSecrets.import.paste.empty", defaultValue: "The clipboard has no text to import."))
            return
        }
        let name = String(localized: "cloudSecrets.import.paste.source", defaultValue: "Clipboard")
        Task { await model.beginImport(text: text, sourceName: name, source: .dotenv("clipboard")) }
    }

    /// Accepts the first dropped file URL.
    static func loadDropped(
        _ providers: [NSItemProvider],
        success: @escaping @MainActor @Sendable (String, String) -> Void,
        failure: @escaping @MainActor @Sendable (String) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url else {
                    failure(String(localized: "cloudSecrets.import.drop.failed", defaultValue: "That item is not a file cmux can read."))
                    return
                }
                load(url, success: success, failure: failure)
            }
        }
        return true
    }

    static func load(
        _ url: URL,
        success: @MainActor (String, String) -> Void,
        failure: @MainActor (String) -> Void
    ) {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            failure(String(localized: "cloudSecrets.import.tooLarge", defaultValue: "That file is larger than 256 KB, which is too large for a .env file."))
            return
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            failure(String(
                format: String(localized: "cloudSecrets.import.unreadable", defaultValue: "cmux could not read %@ as text."),
                name
            ))
            return
        }
        success(text, name)
    }
}
