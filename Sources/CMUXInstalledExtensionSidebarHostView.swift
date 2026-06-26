@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI

struct CMUXInstalledExtensionSidebarHostView: View {
    // Wire messages the host coordinator returns to the extension process.
    // Resolved here, in the app target, so `String(localized:)` binds to the app
    // bundle's localized catalog (including Japanese) rather than the
    // CmuxSidebar package bundle, which carries no catalog.
    private static let hostXPCStrings = CMUXSidebarExtensionHostXPCStrings(
        scopeRejected: String(localized: "sidebar.extensions.action.scopeRejected", defaultValue: "Extension action is not granted"),
        staleConnection: String(localized: "sidebar.extensions.action.staleConnection", defaultValue: "Extension connection is no longer active")
    )

    // DEBUG-only sink injected into the host coordinator so it keeps emitting
    // `extension.sidebar.*` events without the package depending on the app's
    // `cmuxDebugLog`. `nil` in release, matching the original `#if DEBUG` blocks.
#if DEBUG
    private static let hostXPCDebugLog: ((_ message: String) -> Void)? = { message in
        cmuxDebugLog(message)
    }
#else
    private static let hostXPCDebugLog: ((_ message: String) -> Void)? = nil
#endif

    var snapshotProvider: @MainActor () -> CmuxSidebarSnapshot
    var snapshotUpdateToken: UInt64 = 0
    var actionHandler: @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    var onUseDefaultSidebar: @MainActor () -> Void = {}

    @State private var selectionModel = CMUXSidebarExtensionSelectionModel()
    @State private var browserAnchorView: NSView?
    @State private var xpcHost = CMUXSidebarExtensionHostXPC(
        strings: Self.hostXPCStrings,
        debugLog: Self.hostXPCDebugLog
    )
    @State private var effectiveGrant: CMUXSidebarExtensionEffectiveGrant?
    @State private var blockedManifestReason: CMUXSidebarExtensionBlockedReason?
    @State private var isShowingExtensionDetails = false
    @State private var isShowingAccessReview = false
    @State private var keptLimitedManifestKeys = CMUXSidebarExtensionLimitedChoiceStore().choices()
    @State private var hostReloadToken: UInt64 = 0

    var body: some View {
        Group {
            if let identity = selectionModel.identity {
                VStack(alignment: .leading, spacing: 0) {
                    extensionControlStrip(activeIdentity: identity)
                    if let effectiveGrant, shouldShowAccessBanner(identity: identity, effectiveGrant: effectiveGrant) {
                        extensionAccessBanner(identity: identity, effectiveGrant: effectiveGrant)
                    }
                    CMUXSidebarExtensionHostView(
                        identity: identity,
                        onConnection: { connection in
                            xpcHost.attach(
                                connection: connection,
                                bundleIdentifier: identity.bundleIdentifier,
                                snapshotProvider: snapshotProvider,
                                actionHandler: actionHandler,
                                onGrantChanged: { grant in
                                    effectiveGrant = grant
                                },
                                onManifestBlocked: { reason in
                                    blockedManifestReason = reason
                                }
                            )
                        },
                        onDeactivation: { error in
                            xpcHost.invalidate()
                            effectiveGrant = nil
                            if selectionModel.identity?.bundleIdentifier == identity.bundleIdentifier {
                                blockedManifestReason = .connectionInterrupted
                            }
                            selectionModel.errorText = error?.localizedDescription
                        },
                        onTeardown: {
                            xpcHost.invalidate()
                        }
                    )
                    .id("\(identity.bundleIdentifier)-\(hostReloadToken)")
                    .opacity(blockedManifestReason == nil ? 1 : 0)
                    .frame(height: blockedManifestReason == nil ? nil : 0)
                    .accessibilityIdentifier("CMUXExtensionSidebarHostView")
                    .padding(.top, effectiveGrant?.needsAdditionalApproval == true ? 8 : 0)
                    if let blockedManifestReason {
                        blockedExtensionView(reason: blockedManifestReason)
                    }
                }
            } else if selectionModel.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "sidebar.extensions.loading", defaultValue: "Loading sidebar extensions"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(24)
                .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                        )
                    VStack(spacing: 6) {
                        Text(emptyStateTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                        Text(selectionModel.errorText ?? emptyStateDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if selectionModel.disabledExtensionCount > 0 || selectionModel.unapprovedExtensionCount > 0 {
                            Text(extensionAvailabilityDetail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    extensionEmptyActions()
                        .padding(.top, 2)
                }
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(24)
                .accessibilityIdentifier("CMUXExtensionSidebarEmptyState")
            }
        }
        .task {
            xpcHost.update(snapshotProvider: snapshotProvider, actionHandler: actionHandler)
            await selectionModel.observeExtensionAvailability(
                loadFailureText: String(
                    localized: "sidebar.extensions.error",
                    defaultValue: "CMUX could not load sidebar extensions."
                ),
                onSelectedIdentityChange: resetHostForSelectedIdentityChange,
                onLoadFailure: resetHostForLoadFailure
            )
        }
        .onChange(of: snapshotProvider().sequence) { _, _ in
            xpcHost.sendSnapshotDidChange()
        }
        .onChange(of: snapshotUpdateToken) { _, _ in
            xpcHost.sendSnapshotDidChange()
        }
        .onDisappear {
            xpcHost.invalidate()
        }
        .sheet(isPresented: $isShowingAccessReview) {
            if let identity = selectionModel.identity, let effectiveGrant {
                accessReviewSheet(identity: identity, effectiveGrant: effectiveGrant)
            }
        }
    }

    /// Tears down the stale XPC host and clears its effective grant when the
    /// selection model is about to switch the hosted identity. Injected into the
    /// selection model so the model owns selection state while the view keeps
    /// ownership of the live connection.
    private func resetHostForSelectedIdentityChange() {
        xpcHost.invalidate()
        effectiveGrant = nil
    }

    /// Tears down the host and clears blocked-manifest state when identity
    /// discovery fails. Injected into the selection model's failure path.
    private func resetHostForLoadFailure() {
        xpcHost.invalidate()
        blockedManifestReason = nil
    }

    private var emptyStateTitle: String {
        if selectionModel.enabledIdentities.count > 1 {
            return String(localized: "sidebar.extensions.choose.title", defaultValue: "Choose a sidebar extension")
        }
        return String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled")
    }

    private var emptyStateDetail: String {
        if selectionModel.enabledIdentities.count > 1 {
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

    private var extensionAvailabilityDetail: String {
        if selectionModel.unapprovedExtensionCount > 0 {
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
    private func extensionEmptyActions() -> some View {
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
        if selectionModel.enabledIdentities.count > 1 {
            Menu {
                ForEach(selectionModel.enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                    Button {
                        selectionModel.selectExtension(
                            enabledIdentity,
                            onSelectedIdentityChange: resetHostForSelectedIdentityChange
                        )
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

    private func extensionControlStrip(activeIdentity: AppExtensionIdentity?) -> some View {
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

    private func blockedExtensionView(reason: CMUXSidebarExtensionBlockedReason) -> some View {
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

    private func blockedStatusText(reason: CMUXSidebarExtensionBlockedReason) -> String {
        switch reason {
        case .connectionInterrupted:
            return String(localized: "sidebar.extensions.blocked.status.connectionInterrupted", defaultValue: "Blocked, connection interrupted")
        case .manifestTimedOut:
            return String(localized: "sidebar.extensions.blocked.status.manifestTimedOut", defaultValue: "Blocked, configuration timed out")
        case .missingManifest:
            return String(localized: "sidebar.extensions.blocked.status.missingManifest", defaultValue: "Blocked, missing configuration")
        case .invalidManifest:
            return String(localized: "sidebar.extensions.blocked.status.invalidManifest", defaultValue: "Blocked, invalid configuration")
        default:
            return String(localized: "sidebar.extensions.blocked.status.failedManifest", defaultValue: "Blocked, configuration unavailable")
        }
    }

    private func blockedDetailText(reason: CMUXSidebarExtensionBlockedReason) -> String {
        switch reason {
        case .connectionInterrupted:
            return String(localized: "sidebar.extensions.blocked.detail.connectionInterrupted", defaultValue: "CMUX lost the extension connection. No workspace data or actions are being shared.")
        case .manifestTimedOut:
            return String(localized: "sidebar.extensions.blocked.detail.manifestTimedOut", defaultValue: "CMUX did not receive this extension's configuration in time. No workspace data or actions are being shared.")
        case .missingManifest:
            return String(localized: "sidebar.extensions.blocked.detail.missingManifest", defaultValue: "CMUX did not receive a sidebar extension configuration, so no workspace data or actions were shared.")
        case .invalidManifest:
            return String(localized: "sidebar.extensions.blocked.detail.invalidManifest", defaultValue: "CMUX rejected this extension's configuration. No workspace data or actions were shared.")
        default:
            return String(localized: "sidebar.extensions.blocked.detail.failedManifest", defaultValue: "CMUX could not load this extension's configuration. No workspace data or actions were shared.")
        }
    }

    private func detailRow(title: String, value: String) -> some View {
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

    private func permissionSection(effectiveGrant: CMUXSidebarExtensionEffectiveGrant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sidebar.extensions.details.permissions", defaultValue: "Permissions"))
                .font(.system(size: 12, weight: .semibold))
            ForEach(effectiveGrant.manifest.readScopes, id: \.self) { scope in
                permissionRow(
                    title: scope.displayName,
                    detail: scope.permissionDescription,
                    isGranted: effectiveGrant.readScopes.contains(scope)
                )
            }
            ForEach(effectiveGrant.manifest.actionScopes, id: \.self) { scope in
                permissionRow(
                    title: scope.displayName,
                    detail: scope.permissionDescription,
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

    @ViewBuilder
    private func extensionIdentityControl(activeIdentity: AppExtensionIdentity?) -> some View {
        if selectionModel.enabledIdentities.count > 1 {
            Menu {
                ForEach(selectionModel.enabledIdentities, id: \.bundleIdentifier) { enabledIdentity in
                    Button {
                        selectionModel.selectExtension(
                            enabledIdentity,
                            onSelectedIdentityChange: resetHostForSelectedIdentityChange
                        )
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

    private func presentExtensionBrowser() {
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

    private func extensionAccessBanner(
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

    private func accessReviewSheet(
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

    private func shouldShowAccessBanner(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) -> Bool {
        effectiveGrant.needsAdditionalApproval && !keptLimitedManifestKeys.contains(effectiveGrant.limitedChoiceKey(bundleIdentifier: identity.bundleIdentifier))
    }

    private func grantRequestedAccess(
        identity: AppExtensionIdentity,
        effectiveGrant: CMUXSidebarExtensionEffectiveGrant
    ) {
        let key = effectiveGrant.limitedChoiceKey(bundleIdentifier: identity.bundleIdentifier)
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
        let key = effectiveGrant.limitedChoiceKey(bundleIdentifier: identity.bundleIdentifier)
        keptLimitedManifestKeys.insert(key)
        CMUXSidebarExtensionLimitedChoiceStore().insert(key)
        xpcHost.revokeSensitiveAccess(bundleIdentifier: identity.bundleIdentifier)
        self.effectiveGrant = xpcHost.currentEffectiveGrant
        xpcHost.sendSnapshotDidChange()
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
        return pendingReadScopes.map(\.permissionDescription) +
            pendingActionScopes.map(\.permissionDescription)
    }

}

private extension CmuxExtensionScope {
    var displayName: String {
        switch self {
        case .workspaceList:
            return String(localized: "sidebar.extensions.scope.workspaceList", defaultValue: "Workspace list")
        case .workspaceMetadata:
            return String(localized: "sidebar.extensions.scope.workspaceMetadata", defaultValue: "Workspace metadata")
        case .surfaceMetadata:
            return String(localized: "sidebar.extensions.scope.surfaceMetadata", defaultValue: "Surface metadata")
        case .workspacePaths:
            return String(localized: "sidebar.extensions.scope.workspacePaths", defaultValue: "Workspace paths")
        case .notifications:
            return String(localized: "sidebar.extensions.scope.notifications", defaultValue: "Notifications")
        case .networkPorts:
            return String(localized: "sidebar.extensions.scope.networkPorts", defaultValue: "Network ports")
        case .pullRequests:
            return String(localized: "sidebar.extensions.scope.pullRequests", defaultValue: "Pull requests")
        }
    }

    var permissionDescription: String {
        switch self {
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
}

private extension CmuxExtensionActionScope {
    var displayName: String {
        switch self {
        case .createWorkspace:
            return String(localized: "sidebar.extensions.actionScope.createWorkspace", defaultValue: "Create workspaces")
        case .selectWorkspace:
            return String(localized: "sidebar.extensions.actionScope.selectWorkspace", defaultValue: "Select workspaces")
        case .closeWorkspace:
            return String(localized: "sidebar.extensions.actionScope.closeWorkspace", defaultValue: "Close workspaces")
        case .createSurface:
            return String(localized: "sidebar.extensions.actionScope.createSurface", defaultValue: "Create surfaces")
        case .selectSurface:
            return String(localized: "sidebar.extensions.actionScope.selectSurface", defaultValue: "Select surfaces")
        case .closeSurface:
            return String(localized: "sidebar.extensions.actionScope.closeSurface", defaultValue: "Close surfaces")
        case .splitSurface:
            return String(localized: "sidebar.extensions.actionScope.splitSurface", defaultValue: "Split surfaces")
        case .zoomSurface:
            return String(localized: "sidebar.extensions.actionScope.zoomSurface", defaultValue: "Zoom surfaces")
        case .navigateWorkspace:
            return String(localized: "sidebar.extensions.actionScope.navigateWorkspace", defaultValue: "Navigate workspaces")
        case .navigateSurface:
            return String(localized: "sidebar.extensions.actionScope.navigateSurface", defaultValue: "Navigate surfaces")
        case .openURL:
            return String(localized: "sidebar.extensions.actionScope.openURL", defaultValue: "Open URLs")
        case .createWorkspaceWithPath:
            return String(localized: "sidebar.extensions.actionScope.createWorkspaceWithPath", defaultValue: "Create workspaces with paths")
        }
    }

    var permissionDescription: String {
        switch self {
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
