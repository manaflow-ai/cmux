#if os(iOS)
import CmuxMobileDesign
import CmuxSpinner
import SwiftUI
import UniformTypeIdentifiers

private let theme = CmuxMobileTheme.standard

/// Settings → Cloud → Vault (the Mac's Settings → Cloud → Vault, `cmux vault`): off with Turn On;
/// waiting with this phone's code to approve from another device; on with the kept names (values
/// masked, never shown), Add, Edit, Remove, Import from a `.env`, and the devices that hold the vault.
public struct VaultScreen: View {
    @State private var model: VaultModel
    @State private var editing: VaultEditTarget?
    @State private var importing = false
    @State private var importText: VaultImportText?
    @State private var approving: VaultDevice?
    @State private var removingDevice: VaultDevice?

    public init(model: VaultModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        content
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.state == "active" {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Add", systemImage: "plus") {
                            Button("Add Secret", systemImage: "key") { editing = .new }
                            Button("Import from .env…", systemImage: "doc.badge.plus") { importing = true }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("vault.add")
                    }
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(item: $editing) { target in VaultEditSheet(model: model, target: target) }
            .sheet(item: $importText) { text in VaultImportSheet(model: model, text: text) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                guard case let .success(url) = result else { return }
                importText = VaultImportText.read(url)
                if importText == nil { model.failure = String(localized: "That file couldn't be read as a .env file.") }
            }
            .confirmationDialog(approving.map { "Approve “\($0.label)”?" } ?? "", isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } }),
                                titleVisibility: .visible, presenting: approving) { device in
                Button("Approve") { Task { await model.approve(device) } }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text("Approve only if “\(device.label)” shows \(device.safetyCode). It will be able to read every value in your vault.")
            }
            .confirmationDialog(removingDevice.map { "Remove “\($0.label)”?" } ?? "", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } }),
                                titleVisibility: .visible, presenting: removingDevice) { device in
                Button("Remove Device", role: .destructive) { Task { await model.remove(device) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The vault gets a new key, so this device opens nothing kept from now on. Values it already saw are its own: change them at their provider.")
            }
            .alert("Vault", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            // placeholder-ok: the vault's status has not answered yet on this page.
            CmuxSpinner(label: Text("Loading vault…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("vault.loading")
                .placeholderBound("vault.loading", .milliseconds(2000))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load the vault", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .accessibilityIdentifier("vault.failed")
            // The vault reads again by itself, jittered, for as long as this page shows the failure.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 4...8)))
                    guard !Task.isCancelled else { return }
                    await model.load()
                }
            }
        case .loaded:
            List {
                switch model.state {
                case "active": activeSections
                case "pending": pendingSections
                default: offSections
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("vault.\(model.state)")
        }
    }

    // MARK: Off

    @ViewBuilder private var offSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("End-to-end encrypted", systemImage: "lock.shield")
                    .font(.headline)
                Text("Keep API keys and env values once, and every Cloud machine you start gets the ones it needs, even from this iPhone while your Mac is off. cmux Cloud stores only sealed data it can't read.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        Section {
            Button {
                Task { await model.turnOn() }
            } label: {
                HStack {
                    Text(model.state == "not_enrolled" ? "Turn On for This iPhone" : "Turn On")
                    Spacer()
                    if model.busy { ProgressView() }
                }
            }
            .disabled(model.busy)
            .accessibilityIdentifier("vault.turnOn")
        } footer: {
            if model.state == "not_enrolled" {
                Text("Your vault is on for another device. Turning it on here asks one of them to approve this iPhone by its code.")
            } else {
                Text("Off by default. Only your devices hold the vault's key; if you lose all of them, the vault can't be opened.")
            }
        }
    }

    // MARK: Waiting for approval

    @ViewBuilder private var pendingSections: some View {
        Section {
            VStack(spacing: 12) {
                Text("Approve This iPhone")
                    .font(.headline)
                Text(model.status?.safetyCode ?? "")
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("vault.safetyCode")
                Text("On your Mac, open Settings → Cloud → Vault and approve this iPhone when it shows the same code, or run `cmux vault approve` with it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        Section {
            Button("Check Again") { Task { await model.load() } }
                .disabled(model.busy)
                .accessibilityIdentifier("vault.checkAgain")
        }
        devicesSection
    }

    // MARK: On

    @ViewBuilder private var activeSections: some View {
        Section {
            if model.items.isEmpty {
                Text("Nothing kept yet. Add a secret, or import the names from a .env file.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.items) { item in
                Button { editing = .item(item) } label: { VaultItemRow(item: item) }
                    .tint(.primary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.remove(item) } }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = .item(item) }
                        Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.remove(item) } }
                    }
                    .accessibilityIdentifier("vault.item.\(item.name)")
            }
        } header: {
            Text("Secrets")
        } footer: {
            Text("Values stay hidden on every device. Each Cloud machine gets the values in its scope, sealed to that machine.")
        }
        devicesSection
    }

    private var devicesSection: some View {
        Section {
            ForEach(model.devices) { device in
                VaultDeviceRow(device: device, canApprove: model.state == "active" && device.state == "pending") {
                    approving = device
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if model.state == "active", !device.thisDevice {
                        Button("Remove", systemImage: "trash", role: .destructive) { removingDevice = device }
                    }
                }
                .accessibilityIdentifier("vault.device.\(device.id)")
            }
        } header: {
            Text("Devices")
        } footer: {
            if model.state == "active", model.devices.contains(where: { $0.state == "pending" }) {
                Text("Approve a device only after it shows the same code as here.")
            }
        }
    }
}

/// A kept name, its masked value and where it goes.
struct VaultItemRow: View {
    let item: VaultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(item.masked).accessibilityLabel("hidden value")
                Text("·").accessibilityHidden(true)
                Text(item.scopeLabel).lineLimit(1).truncationMode(.middle)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct VaultDeviceRow: View {
    let device: VaultDevice
    let canApprove: Bool
    let approve: () -> Void

    private var symbol: String {
        switch device.kind {
        case "iphone": "iphone"
        case "mac": "laptopcomputer"
        default: "terminal"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.label).lineLimit(1)
                Text(device.thisDevice ? "This iPhone" : device.state == "pending" ? "Waiting · \(device.safetyCode)" : "Active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if canApprove {
                Button("Approve…", action: approve)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vault.approve.\(device.id)")
            }
        }
    }
}

/// What the edit sheet opens on.
enum VaultEditTarget: Identifiable {
    case new
    case item(VaultItem)

    var id: String {
        switch self {
        case .new: "new"
        case let .item(item): item.id
        }
    }
}

/// The scope picker every sheet shares: every machine, a repo, or one machine.
struct VaultScopePicker: View {
    @Binding var kind: VaultScopeKind
    @Binding var target: String

    var body: some View {
        Picker("Available To", selection: $kind) {
            Text("Every Machine").tag(VaultScopeKind.all)
            Text("A Repository").tag(VaultScopeKind.repo)
            Text("One Machine").tag(VaultScopeKind.machine)
        }
        .accessibilityIdentifier("vault.scope")
        if kind == .repo {
            TextField("owner/name", text: $target)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("vault.scope.repo")
        } else if kind == .machine {
            TextField("vm_…", text: $target)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("vault.scope.machine")
        }
    }

    static func split(_ wire: String) -> (VaultScopeKind, String) {
        if wire.hasPrefix("repo:") { return (.repo, String(wire.dropFirst(5))) }
        if wire.hasPrefix("machine:") { return (.machine, String(wire.dropFirst(8))) }
        return (.all, "")
    }
}

/// Add a secret, or give a kept one a new value. The old value is never shown: Edit replaces it.
struct VaultEditSheet: View {
    let model: VaultModel
    let target: VaultEditTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var kind = VaultScopeKind.all
    @State private var scopeTarget = ""
    @State private var saving = false

    private var existing: VaultItem? {
        if case let .item(item) = target { return item }
        return nil
    }

    private var scope: String? { model.scope(kind: kind, target: scopeTarget) }
    private var nameIsValid: Bool { model.isValidName(name) }
    private var canSave: Bool { nameIsValid && !value.isEmpty && scope != nil && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("NAME", text: $name)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(existing != nil)
                        .accessibilityIdentifier("vault.edit.name")
                    SecureField(existing == nil ? "Value" : "New Value", text: $value)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("vault.edit.value")
                } footer: {
                    if !name.isEmpty, !nameIsValid {
                        Text("Use letters, digits and _, not starting with a digit. Names the shell or cmux own (PATH, CMUX_…) can't be kept.")
                    } else if existing != nil {
                        Text("The current value stays hidden. Saving replaces it on every device and machine.")
                    }
                }
                Section {
                    VaultScopePicker(kind: $kind, target: $scopeTarget)
                        .disabled(existing != nil)
                } footer: {
                    Text("A more specific scope wins: one machine over a repository over every machine.")
                }
            }
            .navigationTitle(existing == nil ? "Add Secret" : "Edit Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("vault.edit.save")
                }
            }
            .onAppear {
                guard let existing else { return }
                name = existing.name
                (kind, scopeTarget) = VaultScopePicker.split(existing.scope)
            }
            .onDisappear { value = "" }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() {
        guard let scope else { return }
        saving = true
        let typed = value
        Task {
            let kept = await model.set(name: name, scope: scope, value: typed)
            saving = false
            if kept {
                value = ""
                dismiss()
            }
        }
    }
}

/// A `.env` file's text, held only while the import sheet is open.
struct VaultImportText: Identifiable {
    let id = UUID()
    let fileName: String
    let text: String

    /// The file's text, or nil when it can't be read or is over 256 KiB.
    static func read(_ url: URL) -> VaultImportText? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024 + 1), data.count <= 256 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return VaultImportText(fileName: url.lastPathComponent, text: text)
    }
}

/// Import from a `.env`: a checkbox per name (values are never shown), a scope, Import.
struct VaultImportSheet: View {
    let model: VaultModel
    let text: VaultImportText
    @Environment(\.dismiss) private var dismiss
    @State private var preview: VaultImportPreview?
    @State private var picked: Set<String> = []
    @State private var kind = VaultScopeKind.all
    @State private var scopeTarget = ""
    @State private var importing = false

    private var scope: String? { model.scope(kind: kind, target: scopeTarget) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VaultScopePicker(kind: $kind, target: $scopeTarget)
                }
                if let preview {
                    Section {
                        ForEach(preview.rows) { row in
                            Toggle(isOn: Binding(get: { picked.contains(row.name) }, set: { on in
                                if on { picked.insert(row.name) } else { picked.remove(row.name) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                                    if !row.keepable {
                                        Text("Can't be kept (the shell or cmux owns it)").font(.footnote).foregroundStyle(.secondary)
                                    } else if row.alreadyKept {
                                        Text("Kept already: importing replaces it").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(VaultCheckbox())
                            .disabled(!row.keepable)
                            .accessibilityIdentifier("vault.import.\(row.name)")
                        }
                    } header: {
                        Text(text.fileName)
                    } footer: {
                        if !preview.skippedLines.isEmpty {
                            Text("Lines it couldn't read: \(preview.skippedLines.map(String.init).joined(separator: ", ")).")
                        }
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .navigationTitle("Import from .env")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { run() }
                        .disabled(picked.isEmpty || scope == nil || importing)
                        .accessibilityIdentifier("vault.import.run")
                }
            }
            .task(id: scope) {
                guard let scope else { return }
                guard let read = await model.preview(envText: text.text, scope: scope) else { return dismiss() }
                if preview == nil { picked = Set(read.rows.filter { $0.keepable && !$0.alreadyKept }.map(\.name)) }
                preview = read
            }
            .interactiveDismissDisabled(importing)
        }
    }

    private func run() {
        guard let scope else { return }
        importing = true
        Task {
            let done = await model.importNames(envText: text.text, names: Array(picked), scope: scope)
            importing = false
            if done { dismiss() }
        }
    }
}

/// A leading checkmark circle, as Reminders draws a pick in a list.
struct VaultCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                configuration.label
                Spacer()
            }
        }
        .tint(.primary)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
#endif
