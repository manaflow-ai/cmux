@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Access Review & Permissions
extension CMUXInstalledExtensionSidebarHostView {
    func permissionSection(effectiveGrant: CMUXSidebarExtensionEffectiveGrant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sidebar.extensions.details.permissions", defaultValue: "Permissions"))
                .font(.system(size: 12, weight: .semibold))
            ForEach(effectiveGrant.manifest.readScopes, id: \.self) { scope in
                permissionRow(
                    title: scope.displayName,
                    detail: permissionDescription(scope: scope),
                    isGranted: effectiveGrant.readScopes.contains(scope)
                )
            }
            ForEach(effectiveGrant.manifest.actionScopes, id: \.self) { scope in
                permissionRow(
                    title: scope.displayName,
                    detail: permissionDescription(actionScope: scope),
                    isGranted: effectiveGrant.actionScopes.contains(scope)
                )
            }
        }
    }

    private func permissionRow(title: String, detail: String, isGranted: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isGranted ? .green : .secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(isGranted
                ? String(localized: "sidebar.extensions.details.granted", defaultValue: "Granted")
                : String(localized: "sidebar.extensions.details.pending", defaultValue: "Pending"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    func extensionAccessBanner(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sidebar.extensions.access.title", defaultValue: "Limited extension access"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(String.localizedStringWithFormat(
                String(localized: "sidebar.extensions.access.detail", defaultValue: "%@ will not receive workspace data or run actions until you grant its requested access."),
                effectiveGrant.manifest.displayName
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pendingPermissionDescriptions(effectiveGrant: effectiveGrant), id: \.self) { description in
                    Label(description, systemImage: "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(.top, 2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    limitedAccessActionButtons(identity: identity, effectiveGrant: effectiveGrant)
                }
                VStack(alignment: .leading, spacing: 8) {
                    limitedAccessActionButtons(identity: identity, effectiveGrant: effectiveGrant)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88))
    }

    @ViewBuilder
    private func limitedAccessActionButtons(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> some View {
        Button {
            isShowingAccessReview = true
        } label: {
            Text(String(localized: "sidebar.extensions.access.review", defaultValue: "Review Access..."))
        }
        .controlSize(.small)
        Button {
            keepLimitedAccess(identity: identity, effectiveGrant: effectiveGrant)
        } label: {
            Text(String(localized: "sidebar.extensions.access.keepLimited", defaultValue: "Keep Limited"))
        }
        .controlSize(.small)
    }

    func accessReviewSheet(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 22, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localizedStringWithFormat(
                        String(localized: "sidebar.extensions.access.review.title", defaultValue: "Review access for %@"),
                        effectiveGrant.manifest.displayName
                    ))
                    .font(.system(size: 15, weight: .semibold))
                    Text(identity.bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(String(localized: "sidebar.extensions.access.review.detail", defaultValue: "CMUX will only share the following data and actions if you allow this request."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                detailRow(
                    title: String(localized: "sidebar.extensions.details.manifest", defaultValue: "Configuration"),
                    value: "\(effectiveGrant.manifest.id) · API \(effectiveGrant.manifest.minimumAPIVersion.major).\(effectiveGrant.manifest.minimumAPIVersion.minor)"
                )
                Divider()
                permissionSection(effectiveGrant: effectiveGrant)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "sidebar.extensions.access.keepLimited", defaultValue: "Keep Limited")) {
                    keepLimitedAccess(identity: identity, effectiveGrant: effectiveGrant)
                    isShowingAccessReview = false
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "sidebar.extensions.access.allow", defaultValue: "Allow Requested Access")) {
                    grantRequestedAccess(identity: identity, effectiveGrant: effectiveGrant)
                    isShowingAccessReview = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
    }

    func shouldShowAccessBanner(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> Bool {
        effectiveGrant.needsAdditionalApproval && !keptLimitedManifestKeys.contains(limitedChoiceKey(identity: identity, effectiveGrant: effectiveGrant))
    }

    private func grantRequestedAccess(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) {
        let key = limitedChoiceKey(identity: identity, effectiveGrant: effectiveGrant)
        keptLimitedManifestKeys.remove(key)
        CMUXSidebarExtensionLimitedChoiceStore().remove(key)
        xpcHost.grantRequestedAccess(bundleIdentifier: identity.bundleIdentifier)
        self.effectiveGrant = xpcHost.currentEffectiveGrant
        xpcHost.sendSnapshotDidChange()
    }

    private func keepLimitedAccess(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) {
        let key = limitedChoiceKey(identity: identity, effectiveGrant: effectiveGrant)
        keptLimitedManifestKeys.insert(key)
        CMUXSidebarExtensionLimitedChoiceStore().insert(key)
        xpcHost.revokeSensitiveAccess(bundleIdentifier: identity.bundleIdentifier)
        self.effectiveGrant = xpcHost.currentEffectiveGrant
        xpcHost.sendSnapshotDidChange()
    }

    private func limitedChoiceKey(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> String {
        let readScopes = effectiveGrant.manifest.readScopes.map(\.rawValue).sorted().joined(separator: ",")
        let actionScopes = effectiveGrant.manifest.actionScopes.map(\.rawValue).sorted().joined(separator: ",")
        return "\(identity.bundleIdentifier)|\(effectiveGrant.manifest.id)|\(effectiveGrant.manifest.minimumAPIVersion.major).\(effectiveGrant.manifest.minimumAPIVersion.minor)|\(readScopes)|\(actionScopes)"
    }

    private func pendingPermissionDescriptions(
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> [String] {
        let pendingReadScopes = effectiveGrant.manifest.readScopes.filter {
            !effectiveGrant.readScopes.contains($0)
        }
        let pendingActionScopes = effectiveGrant.manifest.actionScopes.filter {
            !effectiveGrant.actionScopes.contains($0)
        }
        return pendingReadScopes.map(permissionDescription(scope:)) +
            pendingActionScopes.map(permissionDescription(actionScope:))
    }

    private func permissionDescription(scope: CmuxExtensionScope) -> String {
        switch scope {
        case .workspaceList:
            return String(localized: "sidebar.extensions.permission.workspaceList.detail", defaultValue: "Read workspace IDs and names")
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.permission.workspaceMetadata.detail", defaultValue: "Read workspace names, branches, unread counts, and selection")
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.permission.surfaceMetadata.detail", defaultValue: "Read surfaces nested inside each workspace")
        case .workspacePaths:
            return String(localized: "sidebar.extensions.permission.workspacePaths.detail", defaultValue: "Read local workspace and project paths")
        case .notifications:
            return String(localized: "sidebar.extensions.permission.notifications.detail", defaultValue: "Read latest workspace notifications")
        case .networkPorts:
            return String(localized: "sidebar.extensions.permission.networkPorts.detail", defaultValue: "Read listening ports for each workspace")
        case .pullRequests:
            return String(localized: "sidebar.extensions.permission.pullRequests.detail", defaultValue: "Read pull request links associated with workspaces")
        }
    }

    private func permissionDescription(actionScope: CmuxExtensionActionScope) -> String {
        switch actionScope {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.permission.createWorkspace.detail", defaultValue: "Create workspaces")
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.permission.selectWorkspace.detail", defaultValue: "Select a workspace when you click in the extension")
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.permission.closeWorkspace.detail", defaultValue: "Close workspaces from the extension")
        case .createSurface:
            return String(localized: "sidebar.extensions.permission.createSurface.detail", defaultValue: "Create terminal and browser surfaces")
        case .selectSurface:
            return String(localized: "sidebar.extensions.permission.selectSurface.detail", defaultValue: "Select surfaces inside a workspace")
        case .closeSurface:
            return String(localized: "sidebar.extensions.permission.closeSurface.detail", defaultValue: "Close surfaces inside a workspace")
        case .splitSurface:
            return String(localized: "sidebar.extensions.permission.splitSurface.detail", defaultValue: "Create split surfaces")
        case .zoomSurface:
            return String(localized: "sidebar.extensions.permission.zoomSurface.detail", defaultValue: "Toggle surface zoom")
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.permission.navigateWorkspace.detail", defaultValue: "Navigate between workspaces")
        case .navigateSurface:
            return String(localized: "sidebar.extensions.permission.navigateSurface.detail", defaultValue: "Navigate between surfaces")
        case .openURL:
            return String(localized: "sidebar.extensions.permission.openURL.detail", defaultValue: "Open links from the extension")
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.permission.createWorkspaceWithPath.detail", defaultValue: "Create workspaces for specific local folders")
        }
    }

}
