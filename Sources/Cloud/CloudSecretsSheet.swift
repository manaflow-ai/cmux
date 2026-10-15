import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The Cloud Secrets sheet: what every Cloud machine receives, by scope.
/// Header and trust line, scope segments, the list (or the add card, or an
/// import preview), machine delivery state when opened from a machine, and
/// the add/import bar. Values go in through a secure field and never come
/// back out.
struct CloudSecretsSheet: View {
    @Bindable var model: CloudSecretsSheetModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CloudSecretsSheetHeader(machineLabel: model.machineLabel)

            switch model.phase {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "cloudSecrets.sheet.loading", defaultValue: "Reading Cloud Secrets…"))
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                }
            case .loadFailed(let message):
                CloudSecretsMessageBox(text: message, isError: true)
            case .ready:
                content
            }

            if let error = model.actionError {
                CloudSecretsMessageBox(text: error, isError: true)
                    .accessibilityIdentifier("CloudSecretsSheet.actionError")
            }

            CloudSecretsSheetFooter(model: model)
        }
        .padding(20)
        .frame(width: 580)
        .overlay { if isDropTargeted { dropTarget } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            CloudSecretsDotenvFile.loadDropped(providers) { text, name in
                Task { await model.beginImport(text: text, sourceName: name, source: .dotenv(name)) }
            } failure: { message in
                model.showActionError(message)
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "cloudSecrets.remove.confirm", defaultValue: "Remove"), role: .destructive) {
                Task { await model.confirmRemoval() }
            }
            .accessibilityIdentifier("CloudSecretsSheet.confirmRemove")
            Button(String(localized: "cloudSecrets.remove.cancel", defaultValue: "Cancel"), role: .cancel) {
                model.pendingRemoval = nil
            }
        } message: {
            Text(removalMessage)
        }
        .accessibilityIdentifier("CloudSecretsSheet")
    }

    @ViewBuilder
    private var content: some View {
        if let draft = model.importDraft {
            CloudSecretsImportPreviewView(model: model, draft: draft)
        } else if model.isEmptyVault, model.editor == nil {
            CloudSecretsEmptyStateView(
                onAddPreset: { model.beginAdd(name: $0) },
                onImport: { CloudSecretsDotenvFile.choose(into: model) },
                onPaste: { CloudSecretsDotenvFile.paste(into: model) }
            )
        } else {
            CloudSecretsScopeBar(model: model)
            if model.editor != nil {
                CloudSecretsEditorCard(model: model)
            }
            CloudSecretsList(model: model)
            if model.isMachineMode {
                CloudSecretsMachineStatusView(model: model)
            }
        }
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                    Text(String(localized: "cloudSecrets.drop.title", defaultValue: "Drop a .env file to review it before importing"))
                        .cmuxFont(size: 13, weight: .medium)
                }
            }
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var removalTitle: String {
        guard let record = model.pendingRemoval else { return "" }
        return String(
            format: String(localized: "cloudSecrets.remove.title", defaultValue: "Remove %@?"),
            record.name
        )
    }

    private var removalMessage: String {
        guard let record = model.pendingRemoval else { return "" }
        switch record.scope {
        case .all:
            return String(
                localized: "cloudSecrets.remove.message.all",
                defaultValue: "It is deleted from this Mac’s Keychain and removed from every machine at the next sync. Shells that are already open keep the old value."
            )
        case .project(let key):
            return String(
                format: String(
                    localized: "cloudSecrets.remove.message.project",
                    defaultValue: "It is deleted from this Mac’s Keychain and removed from machines linked to %@ at the next sync. Shells that are already open keep the old value."
                ),
                CloudSecretsSheetPresentation.shortProjectLabel(key)
            )
        case .machine(let id):
            return String(
                format: String(
                    localized: "cloudSecrets.remove.message.machine",
                    defaultValue: "It is deleted from this Mac’s Keychain and removed from %@ at the next sync. Shells that are already open keep the old value."
                ),
                model.machineLabels[id] ?? id
            )
        }
    }
}

/// Title, the machine it is about, and the trust line every other control
/// leans on.
private struct CloudSecretsSheetHeader: View {
    let machineLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .cmuxFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Text(String(
                    localized: "cloudSecrets.sheet.subtitle",
                    defaultValue: "API keys and environment variables every Cloud machine receives. Stored in your Mac’s Keychain and sent over each machine’s encrypted link — never to cmux servers."
                ))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        guard let machineLabel else {
            return String(localized: "cloudSecrets.sheet.title", defaultValue: "Cloud Secrets")
        }
        return String(
            format: String(localized: "cloudSecrets.sheet.title.machine", defaultValue: "Cloud Secrets for %@"),
            machineLabel
        )
    }
}

/// A red (or plain) note with the house copy menu, like the Network sheet's.
struct CloudSecretsMessageBox: View {
    let text: String
    var isError: Bool = true

    var body: some View {
        Text(text)
            .cmuxFont(size: 11)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(isError ? 0.08 : 0)))
            .cloudErrorCopyMenu(text)
    }
}

/// Add, Import .env…, Paste .env and Done. ⌘N adds; Esc closes the open
/// card first, then the sheet.
private struct CloudSecretsSheetFooter: View {
    @Bindable var model: CloudSecretsSheetModel

    var body: some View {
        HStack(spacing: 8) {
            // The empty state carries its own add and import actions.
            if !model.hasModalCard, model.phase == .ready, !model.isEmptyVault {
                Button {
                    model.beginAdd()
                } label: {
                    Label(String(localized: "cloudSecrets.add", defaultValue: "Add"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.canAdd)
                .help(addHelp)
                .accessibilityIdentifier("CloudSecretsSheet.add")

                Button(String(localized: "cloudSecrets.import.file", defaultValue: "Import .env…")) {
                    CloudSecretsDotenvFile.choose(into: model)
                }
                .help(String(localized: "cloudSecrets.import.help", defaultValue: "Review the variables in a .env file before storing them. You can also drop a .env file on this window."))
                .accessibilityIdentifier("CloudSecretsSheet.import")

                Button(String(localized: "cloudSecrets.import.paste", defaultValue: "Paste .env")) {
                    CloudSecretsDotenvFile.paste(into: model)
                }
                .help(String(localized: "cloudSecrets.import.paste.help", defaultValue: "Review KEY=VALUE lines from the clipboard before storing them."))
                .accessibilityIdentifier("CloudSecretsSheet.pasteDotenv")
            }
            Spacer()
            if !model.hasModalCard {
                Button(String(localized: "cloudSecrets.done", defaultValue: "Done")) { model.finish() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CloudSecretsSheet.done")
            }
        }
        .padding(.top, 2)
    }

    private var addHelp: String {
        model.canAdd
            ? String(localized: "cloudSecrets.add.help", defaultValue: "Add a secret (⌘N)")
            : String(localized: "cloudSecrets.add.needsMachine", defaultValue: "Open Secrets from a machine’s menu to add a secret for that machine.")
    }
}
