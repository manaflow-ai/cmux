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

    /// The body area's one height. The sheet keeps a single size through the
    /// empty state, the list, the add card, the import preview and a machine's
    /// view, and taller content scrolls inside it, so the sheet never re-centers
    /// on its host as a card opens or closes.
    static let bodyHeight: CGFloat = 320
    /// The footer keeps its height while a card hides its buttons.
    static let footerHeight: CGFloat = 28
    /// Scroll target for the top of the body, where the add card opens.
    private static let topAnchorID = "CloudSecretsSheet.top"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CloudSecretsSheetHeader(machineLabel: model.machineLabel)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 0).id(Self.topAnchorID)
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
                                .id("CloudSecretsSheet.actionError")
                                .accessibilityIdentifier("CloudSecretsSheet.actionError")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
                .frame(height: Self.bodyHeight, alignment: .top)
                // Keep what the person is acting on in view: the add or replace
                // card (it opens at the top), the row the arrow keys selected,
                // and an error.
                .onChange(of: model.editor != nil) { _, isOpen in
                    guard isOpen else { return }
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
                .onChange(of: model.selectionID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: model.actionError) { _, error in
                    guard error != nil else { return }
                    proxy.scrollTo("CloudSecretsSheet.actionError")
                }
            }

            CloudSecretsSheetFooter(model: model)
                .frame(height: Self.footerHeight)
        }
        .padding(20)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
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
            if let machineID = model.machineID {
                CloudAgentReadinessSection(sheet: model, machineID: machineID)
                    .id(machineID)
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
        return CloudSecretsSheetPresentation.removalMessage(
            record.scope,
            machineLabels: model.machineLabels,
            projectLabels: model.projectDisplayNames
        )
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

/// Add, Import .env… (with Paste from Clipboard in its menu) and Done. ⌘N
/// adds; Esc closes the open card first, then the sheet.
private struct CloudSecretsSheetFooter: View {
    @Bindable var model: CloudSecretsSheetModel

    var body: some View {
        HStack(spacing: 8) {
            if !model.hasModalCard, model.phase == .ready {
                Button {
                    model.beginAdd()
                } label: {
                    Label(String(localized: "cloudSecrets.add", defaultValue: "Add"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.canAdd)
                .help(addHelp)
                .accessibilityIdentifier("CloudSecretsSheet.add")

                // The empty state carries its own import starter.
                if !model.isEmptyVault {
                    CloudSecretsImportMenu(model: model)
                }
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

/// Import .env…: clicking chooses a file; its menu also pastes `KEY=VALUE`
/// lines from the clipboard, so the two ways in are one control.
struct CloudSecretsImportMenu: View {
    let model: CloudSecretsSheetModel

    var body: some View {
        Menu {
            Button(String(localized: "cloudSecrets.import.chooseFile", defaultValue: "Choose File\u{2026}")) {
                CloudSecretsDotenvFile.choose(into: model)
            }
            Button(String(localized: "cloudSecrets.import.paste.menu", defaultValue: "Paste from Clipboard")) {
                CloudSecretsDotenvFile.paste(into: model)
            }
            .help(String(localized: "cloudSecrets.import.paste.help", defaultValue: "Review KEY=VALUE lines from the clipboard before storing them."))
            .accessibilityIdentifier("CloudSecretsSheet.pasteDotenv")
        } label: {
            Text(String(localized: "cloudSecrets.import.file", defaultValue: "Import .env…"))
        } primaryAction: {
            CloudSecretsDotenvFile.choose(into: model)
        }
        .fixedSize()
        .help(String(localized: "cloudSecrets.import.help", defaultValue: "Review the variables in a .env file before storing them. You can also drop a .env file on this window."))
        .accessibilityIdentifier("CloudSecretsSheet.import")
    }
}
