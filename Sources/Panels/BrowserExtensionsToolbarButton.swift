import SwiftUI

struct BrowserExtensionsToolbarButton: View {
    @Binding var isPresented: Bool
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let loadSnapshot: @MainActor () async -> BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool

    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(
                systemName: "puzzlepiece.extension",
                pointSize: iconPointSize,
                weight: .medium
            )
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: hitSize, height: hitSize, alignment: .center)
        .safeHelp(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityLabel(String(localized: "browser.extensions.title", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BrowserExtensionsPopoverContent(
                snapshot: snapshot,
                openManager: openManager
            )
        }
        .task(id: isPresented) {
            guard isPresented else { return }
            snapshot = .loading
            snapshot = await loadSnapshot()
        }
    }
}

private struct BrowserExtensionsPopoverContent: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot
    let openManager: @MainActor () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(
                String(localized: "browser.extensions.title", defaultValue: "Extensions"),
                systemImage: "puzzlepiece.extension"
            )
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            BrowserExtensionsPopoverStatus(snapshot: snapshot)

            if snapshot.state == .ready {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        _ = openManager()
                    } label: {
                        Label(
                            String(
                                localized: "browser.extensions.manage",
                                defaultValue: "Manage Extensions"
                            ),
                            systemImage: "puzzlepiece.extension"
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 340)
        .accessibilityIdentifier("BrowserExtensionsPopover")
    }
}

struct BrowserExtensionsManagerPage: View {
    @ObservedObject var panel: BrowserPanel
    let appearance: PanelAppearance
    @State private var snapshot = BrowserWebExtensionsPresentationSnapshot.loading
    @State private var installStatus: InstallStatus?

    private enum InstallStatus: Equatable {
        case installing
        case installed(String)
        case failed(String)
    }

    private struct CatalogItem: Identifiable {
        let id: String
        let name: String
        let detail: String
        let icon: String
    }

    private var commonExtensions: [CatalogItem] {
        [
            CatalogItem(
                id: "bitwarden",
                name: String(localized: "browser.extensions.catalog.bitwarden.name", defaultValue: "Bitwarden"),
                detail: String(localized: "browser.extensions.catalog.bitwarden.detail", defaultValue: "Password manager and autofill"),
                icon: "key.fill"
            ),
            CatalogItem(
                id: "onepassword",
                name: String(localized: "browser.extensions.catalog.onePassword.name", defaultValue: "1Password"),
                detail: String(localized: "browser.extensions.catalog.onePassword.detail", defaultValue: "Password manager and autofill"),
                icon: "key.viewfinder"
            ),
            CatalogItem(
                id: "dark-reader",
                name: String(localized: "browser.extensions.catalog.darkReader.name", defaultValue: "Dark Reader"),
                detail: String(localized: "browser.extensions.catalog.darkReader.detail", defaultValue: "Dark mode for websites"),
                icon: "moon.fill"
            ),
            CatalogItem(
                id: "react-devtools",
                name: String(localized: "browser.extensions.catalog.reactDevTools.name", defaultValue: "React Developer Tools"),
                detail: String(localized: "browser.extensions.catalog.reactDevTools.detail", defaultValue: "Inspect React component trees"),
                icon: "atom"
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                installedSection
                commonSection
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: appearance.backgroundColor))
        .environment(\.colorScheme, cmuxReadableColorScheme(for: appearance.backgroundColor))
        .accessibilityIdentifier("BrowserExtensionsManagerPage")
        .task {
            snapshot = await panel.browserWebExtensionsPresentationSnapshot()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "browser.extensions.manager.title", defaultValue: "Browser Extensions"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "browser.extensions.manager.subtitle", defaultValue: "Add WebExtensions to every cmux browser pane."))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: chooseExtension) {
                Label(
                    String(localized: "browser.extensions.install.action", defaultValue: "Add from Disk…"),
                    systemImage: "plus"
                )
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(installStatus == .installing || snapshot.state != .ready)
            .accessibilityIdentifier("BrowserExtensionsAddFromDiskButton")
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "browser.extensions.installed", defaultValue: "Installed"))
                .font(.headline)
            switch snapshot.state {
            case .unsupported:
                statusCard(
                    String(localized: "browser.extensions.unsupported", defaultValue: "Browser extensions require macOS 15.4 or later."),
                    icon: "exclamationmark.triangle"
                )
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "browser.extensions.loading", defaultValue: "Loading extensions…"))
                        .foregroundStyle(.secondary)
                }
            case .ready:
                if snapshot.extensions.isEmpty && snapshot.failures.isEmpty {
                    statusCard(
                        String(localized: "browser.extensions.empty.title", defaultValue: "No extensions installed"),
                        icon: "puzzlepiece.extension"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(snapshot.extensions) { item in
                            extensionRow(name: item.name, detail: String(localized: "browser.extensions.enabled", defaultValue: "Enabled"), icon: "checkmark.circle.fill", color: .green)
                            Divider()
                        }
                        ForEach(snapshot.failures) { failure in
                            extensionRow(name: failure.entryName, detail: failure.message, icon: "exclamationmark.triangle.fill", color: .orange)
                            Divider()
                        }
                    }
                }
            }

            if let installStatus {
                switch installStatus {
                case .installing:
                    Label(String(localized: "browser.extensions.install.installing", defaultValue: "Installing extension…"), systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                case .installed(let name):
                    Label(
                        String(localized: "browser.extensions.install.success", defaultValue: "Installed \(name)."),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Text(String(localized: "browser.extensions.install.trust", defaultValue: "Only add extensions you trust. cmux grants the permissions and website access declared in the extension manifest."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "browser.extensions.common", defaultValue: "Common extensions"))
                    .font(.headline)
                Spacer()
                Text(String(localized: "browser.extensions.catalog.reviewPending", defaultValue: "Compatibility review pending"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24)], spacing: 0) {
                ForEach(commonExtensions) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            Text(String(localized: "browser.extensions.catalog.explanation", defaultValue: "The cmux catalog will enable one-click installs after each publisher, package, and requested permission set is verified."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusCard(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func extensionRow(name: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
    }

    @MainActor
    private func chooseExtension() {
        let picker = NSOpenPanel()
        picker.title = String(localized: "browser.extensions.install.pickerTitle", defaultValue: "Choose a WebExtension")
        picker.prompt = String(localized: "browser.extensions.install.pickerPrompt", defaultValue: "Add Extension")
        picker.message = String(localized: "browser.extensions.install.pickerMessage", defaultValue: "Choose an unpacked extension folder or a ZIP archive.")
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.begin { response in
            guard response == .OK, let source = picker.url else { return }
            Task { @MainActor in
                installStatus = .installing
                do {
                    let receipt = try await panel.installBrowserWebExtension(from: source)
                    installStatus = .installed(receipt.name)
                    snapshot = await panel.browserWebExtensionsPresentationSnapshot()
                } catch {
                    installStatus = .failed(error.localizedDescription)
                }
            }
        }
    }
}

private struct BrowserExtensionsPopoverStatus: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot

    var body: some View {
        switch snapshot.state {
        case .unsupported:
            Text(
                String(
                    localized: "browser.extensions.unsupported",
                    defaultValue: "Browser extensions require macOS 15.4 or later."
                )
            )
            .foregroundStyle(.secondary)
            .padding(12)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "browser.extensions.loading", defaultValue: "Loading extensions…"))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        case .ready:
            BrowserExtensionsReadyList(snapshot: snapshot)
        }
    }
}

private struct BrowserExtensionsReadyList: View {
    let snapshot: BrowserWebExtensionsPresentationSnapshot

    var body: some View {
        if snapshot.extensions.isEmpty && snapshot.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "browser.extensions.empty.title", defaultValue: "No extensions installed"))
                    .font(.callout.weight(.medium))
                Text(
                    String(
                        localized: "browser.extensions.empty.detail",
                        defaultValue: "Add an unpacked Safari Web Extension or .zip file to the extensions folder."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.extensions) { item in
                        Label(item.name, systemImage: "puzzlepiece.extension")
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    ForEach(snapshot.failures) { failure in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.entryName)
                                    .lineLimit(1)
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }
}
