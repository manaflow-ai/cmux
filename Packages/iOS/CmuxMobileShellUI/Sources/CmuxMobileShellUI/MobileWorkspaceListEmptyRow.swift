#if os(iOS)
import Foundation
import CmuxMobileSupport
import SafariServices
import SwiftUI

private struct MobileDocsSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.view.accessibilityIdentifier = "MobileDocsSafariView"
        controller.view.accessibilityValue = url.absoluteString
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct MobileWorkspaceListEmptyRow: View {
    private static let docsURL = URL(string: "https://cmux.com/docs/ios#prerequisites")!
    private static let retryTimeout: Duration = .seconds(30)

    let retry: (@Sendable () async -> Void)?
    let cancelRetry: (() -> Void)?
    let onLayoutChange: (() -> Void)?
    let shouldCancelRetryOnDisappear: (() -> Bool)?
    let isRetryOwnerCurrentOnDisappear: (() -> Bool)?
    var beginRetry: (() -> UUID?)? = nil
    var cancelRetryAttempt: ((UUID?) -> Void)? = nil
    var cancelRetryOnDisappear: ((UUID?) -> Void)? = nil
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var retryTimeoutTask: Task<Void, Never>?
    @State private var retryAttemptID: UUID?
    @State private var retryRecoveryGeneration: UUID?
    @State private var retryTimedOut = false
    @State private var isDocsPresented = false

    var body: some View {
        // A plain stack, not ContentUnavailableView: this row is self-sized
        // by the workspace table, and ContentUnavailableView fills whatever
        // height it is offered, which stretched the action buttons into
        // label-less capsules.
        VStack(spacing: 16) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(
                    L10n.string(
                        "mobile.workspaces.empty.title",
                        defaultValue: "No workspaces yet"
                    )
                )
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                Text(MobilePairingCopy().emptyWorkspaceMessage)
                    .foregroundStyle(.secondary)
                if retryTimedOut {
                    Text(
                        L10n.string(
                            "mobile.workspaces.empty.retryTimedOut",
                            defaultValue: "The connection is taking longer than expected. Try again or check the setup guide."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MobileWorkspaceEmptyRetryTimedOut")
                }
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                if let retry {
                    Button {
                        guard !isRetrying else { return }
                        let attemptID = UUID()
                        let recoveryGeneration = beginRetry?()
                        retryRecoveryGeneration = recoveryGeneration
                        retryAttemptID = attemptID
                        retryTimedOut = false
                        retryTask?.cancel()
                        retryTimeoutTask?.cancel()
                        isRetrying = true
                        retryTask = Task { @MainActor in
                            defer {
                                if retryAttemptID == attemptID {
                                    retryTask = nil
                                    retryTimeoutTask?.cancel()
                                    retryTimeoutTask = nil
                                    retryAttemptID = nil
                                    retryRecoveryGeneration = nil
                                    isRetrying = false
                                }
                            }
                            guard !Task.isCancelled else { return }
                            await retry()
                        }
                        retryTimeoutTask = Task { @MainActor in
                            do {
                                try await ContinuousClock().sleep(for: Self.retryTimeout)
                            } catch {
                                return
                            }
                            guard retryAttemptID == attemptID else { return }
                            retryAttemptID = nil
                            retryTask?.cancel()
                            (cancelRetryAttempt ?? { _ in cancelRetry?() })(recoveryGeneration)
                            retryTimeoutTask = nil
                            retryTask = nil
                            isRetrying = false
                            retryRecoveryGeneration = nil
                            retryTimedOut = true
                        }
                        } label: {
                            // An HStack, not a Label: in this table-hosted row the
                            // Label icon slot draws in the accent color, which is
                            // invisible on the accent-filled prominent button.
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .accessibilityHidden(true)
                                Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                            }
                        }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isRetrying)
                    .accessibilityIdentifier("MobileWorkspaceEmptyRetry")
                }
                Button {
                    isDocsPresented = true
                } label: {
                    Label(
                        L10n.string(
                            "mobile.workspaces.empty.setupGuide",
                            defaultValue: "See Docs"
                        ),
                        systemImage: "book"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("MobileWorkspaceEmptySetupGuide")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceEmptyState")
        .sheet(isPresented: $isDocsPresented) {
            MobileDocsSafariView(url: Self.docsURL)
                .ignoresSafeArea()
        }
        .onChange(of: retryTimedOut) { _, _ in onLayoutChange?() }
        .onDisappear {
            let hasActiveRetry = isRetrying || retryTask != nil
            if hasActiveRetry {
                let ownerIsCurrent = isRetryOwnerCurrentOnDisappear?() ?? true
                // A missing predicate means this row has no owner that can
                // safely cancel recovery during structural removal. Preserve
                // the task until its explicit completion or timeout.
                let shouldCancel = shouldCancelRetryOnDisappear?() ?? false
                if !ownerIsCurrent || shouldCancel {
                    retryTask?.cancel()
                    if let cancelRetryOnDisappear {
                        cancelRetryOnDisappear(retryRecoveryGeneration)
                    } else if let cancelRetryAttempt {
                        cancelRetryAttempt(retryRecoveryGeneration)
                    } else {
                        cancelRetry?()
                    }
                    retryTimeoutTask?.cancel()
                    retryTask = nil
                    retryAttemptID = nil
                    retryTimeoutTask = nil
                    retryRecoveryGeneration = nil
                    isRetrying = false
                    retryTimedOut = false
                }
            } else if !hasActiveRetry {
                retryTimeoutTask?.cancel()
                retryTask = nil
                retryAttemptID = nil
                retryTimeoutTask = nil
                retryRecoveryGeneration = nil
                isRetrying = false
                retryTimedOut = false
            }
        }
    }
}
#endif
