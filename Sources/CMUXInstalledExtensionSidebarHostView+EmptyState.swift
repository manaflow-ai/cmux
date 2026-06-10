@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Empty State
extension CMUXInstalledExtensionSidebarHostView {
    var emptyStateTitle: String {
        if enabledIdentities.count > 1 {
            return String(localized: "sidebar.extensions.choose.title", defaultValue: "Choose a sidebar extension")
        }
        return String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled")
    }

    var emptyStateDetail: String {
        if enabledIdentities.count > 1 {
            return String(
                localized: "sidebar.extensions.choose.detail",
                defaultValue: "Choose which enabled extension should replace the sidebar."
            )
        }
        return String(
            localized: "sidebar.extensions.empty.detail",
            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
        )
    }

    var extensionAvailabilityDetail: String {
        if unapprovedExtensionCount > 0 {
            return String(
                localized: "sidebar.extensions.unapproved.detail",
                defaultValue: "An installed sidebar extension needs approval before CMUX can use it."
            )
        }
        return String(
            localized: "sidebar.extensions.disabled.detail",
            defaultValue: "A sidebar extension is installed but disabled."
        )
    }

    @ViewBuilder
    func extensionEmptyActions() -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                extensionEmptyActionButtons()
            }
            VStack(spacing: 8) {
                extensionEmptyActionButtons()
            }
        }
    }

    @ViewBuilder
    private func extensionEmptyActionButtons() -> some View {
        if enabledIdentities.count > 1 {
            Menu {
                ForEach(enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                    Button {
                        selectExtension(enabledIdentity)
                    } label: {
                        Label(enabledIdentity.localizedName, systemImage: "puzzlepiece.extension")
                    }
                }
            } label: {
                Label(
                    String(localized: "sidebar.extensions.choose.action", defaultValue: "Choose Extension"),
                    systemImage: "puzzlepiece.extension"
                )
            }
            .menuStyle(.button)
            .controlSize(.small)
        }

        Button {
            presentExtensionBrowser()
        } label: {
            Label(
                String(localized: "sidebar.extensions.manage.short", defaultValue: "Manage"),
                systemImage: "puzzlepiece.extension"
            )
        }
        .controlSize(.small)

        Button {
            onUseDefaultSidebar()
        } label: {
            Label(
                String(localized: "sidebar.extensions.useDefault.short", defaultValue: "Use Default"),
                systemImage: "sidebar.left"
            )
        }
        .controlSize(.small)
    }

}
