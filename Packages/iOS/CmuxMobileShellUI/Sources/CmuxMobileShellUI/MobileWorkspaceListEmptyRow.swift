#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var retryCoordinator = MobileWorkspaceRetryCoordinator()
    @State private var isRetrying = false
    @State private var retryCompletionTask: Task<Void, Never>?
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
                    Task { @MainActor in
                        let started = await retryCoordinator.start(retry)
                        guard let started else {
                            isRetrying = false
                            retryFailure = L10n.string(
                                "mobile.workspaces.empty.retryInProgress",
                                defaultValue: "A refresh is still finishing. Try again in a moment."
                            )
                            return
                        }
                        retryAttemptID = started.id
                        retryCompletionTask = Task { @MainActor in
                            await started.task.value
                            guard retryAttemptID == started.id else { return }
                            retryDeadlineTask?.cancel()
                            retryDeadlineTask = nil
                            retryCompletionTask = nil
                            retryAttemptID = nil
                            isRetrying = false
                        }
                        retryDeadlineTask = Task { @MainActor in
                            do {
                                try await ContinuousClock().sleep(for: .seconds(15))
                            } catch {
                                return
                            }
                            guard retryAttemptID == started.id else { return }
                            await retryCoordinator.cancel(started.id)
                            retryCompletionTask?.cancel()
                            retryCompletionTask = nil
                            retryDeadlineTask = nil
                            retryAttemptID = nil
                            isRetrying = false
                            retryFailure = L10n.string(
                                "mobile.workspaces.empty.retryFailed",
                                defaultValue: "Couldn’t refresh. Try again."
                            )
                        }
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
            retryCompletionTask?.cancel()
            retryDeadlineTask?.cancel()
            retryCompletionTask = nil
            retryDeadlineTask = nil
            let attemptID = retryAttemptID
            retryAttemptID = nil
            isRetrying = false
            Task {
                await retryCoordinator.cancelActive(attemptID)
            }
        }
    }
}
#endif
