@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI

struct CMUXInstalledExtensionSidebarHostView: View {
    static let selectedExtensionBundleIDDefaultsKey = "cmuxExtensionSidebar.selectedExtensionBundleId"
    static let selectedExtensionNameDefaultsKey = "cmuxExtensionSidebar.selectedExtensionName"

    var snapshotProvider: @MainActor () -> CmuxSidebarSnapshot
    var snapshotUpdateToken: UInt64 = 0
    var actionHandler: @MainActor (CmuxSidebarAction) -> CmuxSidebarActionResult
    var onUseDefaultSidebar: @MainActor () -> Void = {}

    @State var identity: AppExtensionIdentity?
    @State var enabledIdentities: [AppExtensionIdentity] = []
    @State var selectedExtensionBundleID = UserDefaults.standard.string(
        forKey: Self.selectedExtensionBundleIDDefaultsKey
    )
    @State var isLoading = true
    @State var errorText: String?
    @State var disabledExtensionCount = 0
    @State var unapprovedExtensionCount = 0
    @State var browserAnchorView: NSView?
    @State var xpcHost = CMUXSidebarExtensionHostXPC()
    @State var effectiveGrant: CMUXSidebarExtensionEffectiveGrant?
    @State var blockedManifestReason: String?
    @State var isShowingExtensionDetails = false
    @State var isShowingAccessReview = false
    @State var keptLimitedManifestKeys = CMUXSidebarExtensionLimitedChoiceStore().choices()
    @State var hostReloadToken: UInt64 = 0

    var body: some View {
        Group {
            if let identity {
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
                            if self.identity?.bundleIdentifier == identity.bundleIdentifier {
                                blockedManifestReason = "connectionInterrupted"
                            }
                            errorText = error?.localizedDescription
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
            } else if isLoading {
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
                        Text(errorText ?? emptyStateDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if disabledExtensionCount > 0 || unapprovedExtensionCount > 0 {
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
            await observeExtensionAvailability()
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
            if let identity, let effectiveGrant {
                accessReviewSheet(identity: identity, effectiveGrant: effectiveGrant)
            }
        }
    }

}

