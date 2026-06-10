@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Control Strip & Details Popover
extension CMUXInstalledExtensionSidebarHostView {
    func extensionControlStrip(activeIdentity: AppExtensionIdentity?) -> some View {
        HStack(spacing: 8) {
            extensionIdentityControl(activeIdentity: activeIdentity)
            Spacer(minLength: 8)
            if effectiveGrant?.needsAdditionalApproval == true {
                Button {
                    isShowingAccessReview = true
                } label: {
                    Label(
                        String(localized: "sidebar.extensions.access.statusLimited", defaultValue: "Limited"),
                        systemImage: "lock"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help(String(localized: "sidebar.extensions.access.statusLimited.help", defaultValue: "This extension has limited access."))
            }
            Button {
                isShowingExtensionDetails = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(String(localized: "sidebar.extensions.details.help", defaultValue: "Show extension details"))
            .popover(isPresented: $isShowingExtensionDetails, arrowEdge: .top) {
                extensionDetailsPopover(activeIdentity: activeIdentity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, SidebarWorkspaceScrollInsets.workspaceList.top + 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TitlebarControlAnchorView { browserAnchorView = $0 })
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.86))
    }

    private func extensionDetailsPopover(activeIdentity: AppExtensionIdentity?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 18, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeIdentity?.localizedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(String(localized: "sidebar.extensions.details.runtime", defaultValue: "Secure extension connection"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                detailRow(
                    title: String(localized: "sidebar.extensions.details.status", defaultValue: "Status"),
                    value: blockedManifestReason.map(blockedStatusText(reason:)) ?? (activeIdentity == nil
                        ? String(localized: "sidebar.extensions.details.statusWaiting", defaultValue: "Waiting for an enabled extension")
                        : String(localized: "sidebar.extensions.details.statusActive", defaultValue: "Connected"))
                )
                if let activeIdentity {
                    detailRow(
                        title: String(localized: "sidebar.extensions.details.bundle", defaultValue: "Bundle"),
                        value: activeIdentity.bundleIdentifier
                    )
                }
                if let manifest = effectiveGrant?.manifest {
                    detailRow(
                        title: String(localized: "sidebar.extensions.details.manifest", defaultValue: "Configuration"),
                        value: "\(manifest.id) · API \(manifest.minimumAPIVersion.major).\(manifest.minimumAPIVersion.minor)"
                    )
                }
            }

            if let effectiveGrant {
                Divider()
                permissionSection(effectiveGrant: effectiveGrant)
            } else if let blockedManifestReason {
                Divider()
                Text(blockedDetailText(reason: blockedManifestReason))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let activeIdentity, let effectiveGrant {
                    HStack(spacing: 8) {
                        Button(String(localized: "sidebar.extensions.access.review", defaultValue: "Review Access...")) {
                            isShowingAccessReview = true
                        }
                        .controlSize(.small)
                        .disabled(!effectiveGrant.needsAdditionalApproval)

                        Button(String(localized: "sidebar.extensions.access.keepLimited", defaultValue: "Keep Limited")) {
                            xpcHost.revokeSensitiveAccess(bundleIdentifier: activeIdentity.bundleIdentifier)
                            self.effectiveGrant = xpcHost.currentEffectiveGrant
                            xpcHost.sendSnapshotDidChange()
                        }
                        .controlSize(.small)
                        .disabled(!effectiveGrant.hasSensitiveAccess)
                    }
                }
                HStack(spacing: 8) {
                    Button(String(localized: "sidebar.extensions.manage.short", defaultValue: "Manage")) {
                        isShowingExtensionDetails = false
                        presentExtensionBrowser()
                    }
                    .controlSize(.small)
                    Button(String(localized: "sidebar.extensions.useDefault.short", defaultValue: "Use Default")) {
                        isShowingExtensionDetails = false
                        onUseDefaultSidebar()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func extensionIdentityControl(activeIdentity: AppExtensionIdentity?) -> some View {
        if enabledIdentities.count > 1 {
            Menu {
                ForEach(enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                    Button {
                        selectExtension(enabledIdentity)
                    } label: {
                        Label(
                            enabledIdentity.localizedName,
                            systemImage: enabledIdentity.bundleIdentifier == activeIdentity?.bundleIdentifier ? "checkmark" : "puzzlepiece.extension"
                        )
                    }
                }
            } label: {
                Label(
                    activeIdentity?.localizedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar"),
                    systemImage: "puzzlepiece.extension"
                )
                .lineLimit(1)
            }
            .menuStyle(.button)
            .controlSize(.small)
        } else {
            Label(
                activeIdentity?.localizedName ?? String(localized: "sidebar.provider.extensions.title", defaultValue: "Extension Sidebar"),
                systemImage: "puzzlepiece.extension"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    func presentExtensionBrowser() {
        guard let anchorView = browserAnchorView
            ?? NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView else { return }
        AppDelegate.shared?.openSidebarExtensionBrowser(
            from: anchorView,
            title: String(
                localized: "sidebar.extensions.browser.title",
                defaultValue: "Sidebar Extensions"
            )
        )
    }

}
