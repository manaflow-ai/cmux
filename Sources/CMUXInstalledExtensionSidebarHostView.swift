@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxSidebarUI
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

    // Empty/chooser-state copy resolved app-side so `String(localized:)` binds to
    // the app bundle's localized catalog (including Japanese), then passed into
    // the CmuxSidebarUI `ExtensionSidebarEmptyStateView` leaf.
    private static let emptyStateStrings = ExtensionSidebarEmptyStateStrings(
        chooseTitle: String(localized: "sidebar.extensions.choose.title", defaultValue: "Choose a sidebar extension"),
        emptyTitle: String(localized: "sidebar.extensions.empty.title", defaultValue: "No sidebar extension enabled"),
        chooseDetail: String(
            localized: "sidebar.extensions.choose.detail",
            defaultValue: "Choose which enabled extension should replace the sidebar."
        ),
        emptyDetail: String(
            localized: "sidebar.extensions.empty.detail",
            defaultValue: "Install and enable a CMUX sidebar extension to show it here."
        ),
        unapprovedDetail: String(
            localized: "sidebar.extensions.unapproved.detail",
            defaultValue: "An installed sidebar extension needs approval before CMUX can use it."
        ),
        disabledDetail: String(
            localized: "sidebar.extensions.disabled.detail",
            defaultValue: "A sidebar extension is installed but disabled."
        ),
        chooseAction: String(localized: "sidebar.extensions.choose.action", defaultValue: "Choose Extension"),
        manage: String(localized: "sidebar.extensions.manage.short", defaultValue: "Manage"),
        useDefault: String(localized: "sidebar.extensions.useDefault.short", defaultValue: "Use Default")
    )

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
                ExtensionSidebarEmptyStateView(
                    enabledIdentities: selectionModel.enabledIdentities,
                    errorText: selectionModel.errorText,
                    disabledExtensionCount: selectionModel.disabledExtensionCount,
                    unapprovedExtensionCount: selectionModel.unapprovedExtensionCount,
                    strings: Self.emptyStateStrings,
                    onSelect: { enabledIdentity in
                        selectionModel.selectExtension(
                            enabledIdentity,
                            onSelectedIdentityChange: resetHostForSelectedIdentityChange
                        )
                    },
                    onManage: { presentExtensionBrowser() },
                    onUseDefault: { onUseDefaultSidebar() }
                )
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
                ExtensionDetailRow(
                    title: String(localized: "sidebar.extensions.details.status", defaultValue: "Status"),
                    value: blockedManifestReason?.blockedStatusText ?? (activeIdentity == nil
                        ? String(localized: "sidebar.extensions.details.statusWaiting", defaultValue: "Waiting for an enabled extension")
                        : String(localized: "sidebar.extensions.details.statusActive", defaultValue: "Connected"))
                )
                if let activeIdentity {
                    ExtensionDetailRow(
                        title: String(localized: "sidebar.extensions.details.bundle", defaultValue: "Bundle"),
                        value: activeIdentity.bundleIdentifier
                    )
                }
                if let manifest = effectiveGrant?.manifest {
                    ExtensionDetailRow(
                        title: String(localized: "sidebar.extensions.details.manifest", defaultValue: "Configuration"),
                        value: "\(manifest.id) · API \(manifest.minimumAPIVersion.major).\(manifest.minimumAPIVersion.minor)"
                    )
                }
            }

            if let effectiveGrant {
                Divider()
                ExtensionPermissionSection(grant: effectiveGrant)
            } else if let blockedManifestReason {
                Divider()
                Text(blockedManifestReason.blockedDetailText)
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
            Text(reason.blockedDetailText)
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
                ForEach(effectiveGrant.pendingPermissionDescriptions, id: \.self) { description in
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
                ExtensionDetailRow(
                    title: String(localized: "sidebar.extensions.details.manifest", defaultValue: "Configuration"),
                    value: "\(effectiveGrant.manifest.id) · API \(effectiveGrant.manifest.minimumAPIVersion.major).\(effectiveGrant.manifest.minimumAPIVersion.minor)"
                )
                Divider()
                ExtensionPermissionSection(grant: effectiveGrant)
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

}
