import SwiftUI

struct BrowserExtensionsToolbarButton: View {
    @Binding var isPresented: Bool
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let loadSnapshot: @MainActor () async -> BrowserWebExtensionsPresentationSnapshot
    let openDirectory: @MainActor () -> Bool

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
                openDirectory: openDirectory
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
    let openDirectory: @MainActor () -> Bool

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
                        _ = openDirectory()
                    } label: {
                        Label(
                            String(
                                localized: "browser.extensions.openFolder",
                                defaultValue: "Open Extensions Folder"
                            ),
                            systemImage: "folder"
                        )
                    }

                    Text(
                        String(
                            localized: "browser.extensions.restartHint",
                            defaultValue: "Restart cmux after adding or removing extensions."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(width: 340)
        .accessibilityIdentifier("BrowserExtensionsPopover")
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
