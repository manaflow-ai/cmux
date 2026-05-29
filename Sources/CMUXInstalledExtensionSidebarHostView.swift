import CMUXExtensionClient
import ExtensionFoundation
import SwiftUI

struct CMUXInstalledExtensionSidebarHostView: View {
    @State private var identity: AppExtensionIdentity?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if let identity {
                CMUXSidebarExtensionHostView(identity: identity)
                    .accessibilityIdentifier("CMUXExtensionSidebarHostView")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "sidebar.extensions.loading", defaultValue: "Loading sidebar extensions"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(errorText ?? String(
                            localized: "sidebar.extensions.empty.detail",
                            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
                        ))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, SidebarWorkspaceScrollInsets.workspaceList.top + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
            }
        }
        .task {
            await loadExtension()
        }
    }

    private func loadExtension() async {
        isLoading = true
        errorText = nil
        do {
            let update = try await Task.detached(priority: .userInitiated) {
                var identities = try AppExtensionIdentity.matching(
                    appExtensionPointIDs: CMUXSidebarExtensionPoint.identifier
                )
                .makeAsyncIterator()
                return await identities.next() ?? []
            }.value
            identity = update.sorted { $0.localizedName < $1.localizedName }.first
            isLoading = false
        } catch {
            identity = nil
            isLoading = false
            errorText = String(
                localized: "sidebar.extensions.error",
                defaultValue: "CMUX could not load sidebar extensions."
            )
        }
    }
}
