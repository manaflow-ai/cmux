@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Blocked Extension State
extension CMUXInstalledExtensionSidebarHostView {
    func blockedExtensionView(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
            Text(String(localized: "sidebar.extensions.blocked.title", defaultValue: "Extension Blocked"))
                .font(.system(size: 13, weight: .semibold))
            Text(blockedDetailText(reason: reason))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    blockedExtensionActionButtons()
                }
                VStack(alignment: .leading, spacing: 8) {
                    blockedExtensionActionButtons()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("CMUXExtensionSidebarBlockedState")
    }

    @ViewBuilder
    private func blockedExtensionActionButtons() -> some View {
        Button {
            blockedManifestReason = nil
            effectiveGrant = nil
            xpcHost.invalidate()
            hostReloadToken &+= 1
        } label: {
            Label(
                String(localized: "sidebar.extensions.retry", defaultValue: "Try Again"),
                systemImage: "arrow.clockwise"
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

        Button {
            presentExtensionBrowser()
        } label: {
            Label(
                String(localized: "sidebar.extensions.manage.short", defaultValue: "Manage"),
                systemImage: "puzzlepiece.extension")
        }
        .controlSize(.small)
    }

    func blockedStatusText(reason: String) -> String {
        switch reason {
        case "connectionInterrupted":
            return String(localized: "sidebar.extensions.blocked.status.connectionInterrupted", defaultValue: "Blocked, connection interrupted")
        case "manifestTimedOut":
            return String(localized: "sidebar.extensions.blocked.status.manifestTimedOut", defaultValue: "Blocked, configuration timed out")
        case "missingManifest":
            return String(localized: "sidebar.extensions.blocked.status.missingManifest", defaultValue: "Blocked, missing configuration")
        case "invalidManifest":
            return String(localized: "sidebar.extensions.blocked.status.invalidManifest", defaultValue: "Blocked, invalid configuration")
        default:
            return String(localized: "sidebar.extensions.blocked.status.failedManifest", defaultValue: "Blocked, configuration unavailable")
        }
    }

    func blockedDetailText(reason: String) -> String {
        switch reason {
        case "connectionInterrupted":
            return String(localized: "sidebar.extensions.blocked.detail.connectionInterrupted", defaultValue: "CMUX lost the extension connection. No workspace data or actions are being shared.")
        case "manifestTimedOut":
            return String(localized: "sidebar.extensions.blocked.detail.manifestTimedOut", defaultValue: "CMUX did not receive this extension's configuration in time. No workspace data or actions are being shared.")
        case "missingManifest":
            return String(localized: "sidebar.extensions.blocked.detail.missingManifest", defaultValue: "CMUX did not receive a sidebar extension configuration, so no workspace data or actions were shared.")
        case "invalidManifest":
            return String(localized: "sidebar.extensions.blocked.detail.invalidManifest", defaultValue: "CMUX rejected this extension's configuration. No workspace data or actions were shared.")
        default:
            return String(localized: "sidebar.extensions.blocked.detail.failedManifest", defaultValue: "CMUX could not load this extension's configuration. No workspace data or actions were shared.")
        }
    }

}
