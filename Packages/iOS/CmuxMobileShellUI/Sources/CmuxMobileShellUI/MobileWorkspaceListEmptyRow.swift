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
    private static let docsURL = URL(string: "https://cmux.com/docs/ios#setup")!
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
        ContentUnavailableView {
            Label(
                L10n.string(
                    "mobile.workspaces.empty.title",
                    defaultValue: "No workspaces yet"
                ),
                systemImage: "macbook.and.iphone"
            )
        } description: {
            VStack(spacing: 8) {
                Text(MobilePairingCopy().emptyWorkspaceMessage)
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
        } actions: {
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
                        Label {
                            Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                        } icon: {
                            Image(systemName: "arrow.clockwise")
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
                let shouldCancel = shouldCancelRetryOnDisappear?() ?? true
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
