#if os(iOS)
import Foundation
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    private static let retryTimeout: Duration = .seconds(30)

    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var retryTimeoutTask: Task<Void, Never>?
    @State private var retryAttemptID: UUID?
    @State private var retryTimedOut = false

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
                    retryAttemptID = attemptID
                    retryTimedOut = false
                    retryTask?.cancel()
                    retryTimeoutTask?.cancel()
                    isRetrying = true
                    retryTask = Task { @MainActor in
                        defer {
                            guard retryAttemptID == attemptID else { return }
                            retryTask = nil
                            retryTimeoutTask?.cancel()
                            retryTimeoutTask = nil
                            isRetrying = false
                        }
                        await retry()
                    }
                    retryTimeoutTask = Task { @MainActor in
                        do {
                            try await ContinuousClock().sleep(for: Self.retryTimeout)
                        } catch {
                            return
                        }
                        guard retryAttemptID == attemptID else { return }
                        retryTimeoutTask = nil
                        isRetrying = false
                        retryTimedOut = true
                    }
                } label: {
                    Label {
                        Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                    } icon: {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRetrying)
                .accessibilityIdentifier("MobileWorkspaceEmptyRetry")
            }
            Link(destination: URL(string: "https://cmux.com/docs/ios#setup")!) {
                Label(
                    L10n.string(
                        "mobile.workspaces.empty.setupGuide",
                        defaultValue: "Set Up cmux iOS"
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
        .onDisappear {
            retryTask?.cancel()
            retryTimeoutTask?.cancel()
            retryTask = nil
            retryTimeoutTask = nil
            retryAttemptID = nil
            isRetrying = false
            retryTimedOut = false
        }
    }
}
#endif
