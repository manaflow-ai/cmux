#if os(iOS)
import CmuxMobileSSH
import CmuxMobileSupport
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One remote folder: entries (folders first), pull to refresh, per-row
/// actions in a context menu and swipe, and an Add menu for uploads and
/// new folders.
struct SSHDirectoryView: View {
    let model: SSHFileBrowserModel
    let path: String
    let actions: SSHFileBrowserActions

    @State private var isImportingFiles = false
    @State private var isPickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isNewFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: SFTPEntry?
    @State private var renameText = ""
    @State private var deleteTarget: SFTPEntry?

    var body: some View {
        content
            .navigationTitle(SSHFileBrowserModel.displayName(of: path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let transfer = model.transfer {
                    SSHTransferProgressBar(transfer: transfer)
                }
            }
            .task(id: path) {
                if model.listing(for: path) == nil { await model.load(path) }
            }
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task { await uploadFiles(urls) }
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $photoSelection,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task { await uploadPhotos(items) }
            }
            .alert(
                L10n.string("mobile.ssh.files.newFolder.title", defaultValue: "New Folder"),
                isPresented: $isNewFolderPresented
            ) {
                TextField(
                    L10n.string("mobile.ssh.files.newFolder.placeholder", defaultValue: "Folder name"),
                    text: $newFolderName
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button(L10n.string("mobile.ssh.files.cancel", defaultValue: "Cancel"), role: .cancel) {}
                Button(L10n.string("mobile.ssh.files.newFolder.create", defaultValue: "Create")) {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    guard SSHFileBrowserModel.isValidName(name) else { return }
                    Task { await model.makeFolder(named: name, in: path) }
                }
            }
            .alert(
                L10n.string("mobile.ssh.files.rename.title", defaultValue: "Rename"),
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { entry in
                TextField(entry.name, text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.string("mobile.ssh.files.cancel", defaultValue: "Cancel"), role: .cancel) {}
                Button(L10n.string("mobile.ssh.files.rename.save", defaultValue: "Rename")) {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    guard SSHFileBrowserModel.isValidName(name), name != entry.name else { return }
                    Task { await model.rename(entry, to: name, in: path) }
                }
            }
            .confirmationDialog(
                deleteTarget.map { deleteTitle(for: $0) } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { entry in
                Button(L10n.string("mobile.ssh.files.delete.confirm", defaultValue: "Delete"), role: .destructive) {
                    Task { await model.delete(entry, in: path) }
                }
            } message: { _ in
                Text(L10n.string(
                    "mobile.ssh.files.delete.message",
                    defaultValue: "This deletes it from the computer. You can't undo this."
                ))
            }
            .alert(
                L10n.string("mobile.ssh.files.error.title", defaultValue: "Couldn't Complete"),
                isPresented: Binding(
                    get: { model.actionError != nil },
                    set: { if !$0 { model.actionError = nil } }
                )
            ) {
                Button(L10n.string("mobile.ssh.files.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let listing = model.listing(for: path) {
            List {
                Section {
                    ForEach(listing.entries, id: \.name) { entry in
                        row(entry)
                    }
                } header: {
                    Text(path)
                        .font(.caption.monospaced())
                        .textCase(nil)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.head)
                } footer: {
                    if listing.entries.isEmpty {
                        Text(L10n.string("mobile.ssh.files.empty", defaultValue: "This folder is empty."))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.load(path) }
            .accessibilityIdentifier("ssh.files.list")
        } else if let error = model.listingErrors[path] {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.ssh.files.folderUnavailable", defaultValue: "Can't Open Folder"),
                    systemImage: "folder.badge.questionmark"
                )
            } description: {
                Text(error)
            } actions: {
                Button(L10n.string("mobile.ssh.files.retry", defaultValue: "Try Again")) {
                    Task { await model.load(path) }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ entry: SFTPEntry) -> some View {
        let remotePath = SSHFileBrowserModel.join(path, entry.name)
        return Button {
            Task { await open(entry, remotePath: remotePath) }
        } label: {
            SSHFileRow(entry: entry)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("ssh.files.row.\(entry.name)")
        .contextMenu {
            if let insertPath = actions.insertPath {
                Button {
                    insertPath(remotePath)
                } label: {
                    Label(
                        L10n.string("mobile.ssh.files.insertPath", defaultValue: "Insert Path in Terminal"),
                        systemImage: "text.cursor"
                    )
                }
            }
            Button {
                UIPasteboard.general.string = remotePath
            } label: {
                Label(
                    L10n.string("mobile.ssh.files.copyPath", defaultValue: "Copy Path"),
                    systemImage: "doc.on.doc"
                )
            }
            Button {
                renameText = entry.name
                renameTarget = entry
            } label: {
                Label(
                    L10n.string("mobile.ssh.files.rename.action", defaultValue: "Rename…"),
                    systemImage: "pencil"
                )
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label(
                    L10n.string("mobile.ssh.files.delete.action", defaultValue: "Delete…"),
                    systemImage: "trash"
                )
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label(
                    L10n.string("mobile.ssh.files.delete.confirm", defaultValue: "Delete"),
                    systemImage: "trash"
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.string("mobile.ssh.files.done", defaultValue: "Done"), action: actions.done)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    isImportingFiles = true
                } label: {
                    Label(
                        L10n.string("mobile.ssh.files.upload.files", defaultValue: "Upload from Files…"),
                        systemImage: "folder"
                    )
                }
                .accessibilityIdentifier("ssh.files.upload.files")
                Button {
                    isPickingPhotos = true
                } label: {
                    Label(
                        L10n.string("mobile.ssh.files.upload.photos", defaultValue: "Upload from Photos…"),
                        systemImage: "photo.on.rectangle"
                    )
                }
                .accessibilityIdentifier("ssh.files.upload.photos")
                Divider()
                Button {
                    newFolderName = ""
                    isNewFolderPresented = true
                } label: {
                    Label(
                        L10n.string("mobile.ssh.files.newFolder.action", defaultValue: "New Folder…"),
                        systemImage: "folder.badge.plus"
                    )
                }
                .accessibilityIdentifier("ssh.files.newFolder")
            } label: {
                Label(
                    L10n.string("mobile.ssh.files.add", defaultValue: "Add"),
                    systemImage: "plus"
                )
            }
            .disabled(model.transfer != nil)
            .accessibilityIdentifier("ssh.files.upload")
        }
    }

    private func deleteTitle(for entry: SFTPEntry) -> String {
        String(
            format: L10n.string("mobile.ssh.files.delete.titleFormat", defaultValue: "Delete “%@”?"),
            entry.name
        )
    }

    private func open(_ entry: SFTPEntry, remotePath: String) async {
        let isDirectory = entry.isSymlink
            ? await model.resolvesToDirectory(remotePath)
            : entry.isDirectory
        actions.open(isDirectory ? .directory(remotePath) : .file(path: remotePath, name: entry.name))
    }

    private func uploadFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            await model.upload(from: url, preferredName: url.lastPathComponent, into: path)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        let staging = model.downloadsDirectory.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let name = Self.photoFileName(index: index, ext: ext, date: Date())
                let local = staging.appendingPathComponent(name)
                try data.write(to: local)
                await model.upload(from: local, preferredName: name, into: path)
                try? FileManager.default.removeItem(at: local)
            } catch {
                model.actionError = L10n.string(
                    "mobile.ssh.files.error.photoLoad",
                    defaultValue: "Couldn't read that photo from your library."
                )
            }
        }
    }

    static func photoFileName(index: Int, ext: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = index == 0 ? "" : "-\(index + 1)"
        return "Photo-\(formatter.string(from: date))\(suffix).\(ext)"
    }
}

/// Icon, name, size, and modified date for one entry.
struct SSHFileRow: View {
    let entry: SFTPEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if entry.isSymlink { return "arrow.up.right.square" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.isDirectory, let size = entry.attributes.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
        }
        if let modified = entry.attributes.modificationTime {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

/// Determinate transfer progress pinned above the bottom edge.
struct SSHTransferProgressBar: View {
    let transfer: SSHFileBrowserModel.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView(value: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ssh.files.transfer")
    }

    private var title: String {
        switch transfer.kind {
        case .upload:
            String(
                format: L10n.string("mobile.ssh.files.uploadingFormat", defaultValue: "Uploading %@…"),
                transfer.name
            )
        case .download:
            String(
                format: L10n.string("mobile.ssh.files.downloadingFormat", defaultValue: "Downloading %@…"),
                transfer.name
            )
        }
    }
}
#endif
