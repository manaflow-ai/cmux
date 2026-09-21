#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var retryDeadlineTask: Task<Void, Never>?
    @State private var retryAttemptID: UUID?
    @State private var retryFailure: String?

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
            Text(MobilePairingCopy().emptyWorkspaceMessage)
        } actions: {
            if let retry {
                Button {
                    guard !isRetrying else { return }
                    retryFailure = nil
                    isRetrying = true
                    let attemptID = UUID()
                    retryAttemptID = attemptID
                    let task = Task { @MainActor in
                        defer {
                            guard retryAttemptID == attemptID else { return }
                            retryDeadlineTask?.cancel()
                            retryDeadlineTask = nil
                            retryTask = nil
                            isRetrying = false
                        }
                        await retry()
                    }
                    retryTask = task
                    retryDeadlineTask = Task { @MainActor in
                        do {
                            try await ContinuousClock().sleep(for: .seconds(15))
                        } catch {
                            return
                        }
                        guard retryAttemptID == attemptID else { return }
                        retryTask?.cancel()
                        retryTask = nil
                        retryDeadlineTask = nil
                        isRetrying = false
                        retryFailure = L10n.string(
                            "mobile.workspaces.empty.retryFailed",
                            defaultValue: "Couldn’t refresh. Try again."
                        )
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
            if let retryFailure {
                Text(retryFailure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("MobileWorkspaceEmptyRetryError")
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
            retryDeadlineTask?.cancel()
            retryTask = nil
            retryDeadlineTask = nil
        }
    }
}
#endif
