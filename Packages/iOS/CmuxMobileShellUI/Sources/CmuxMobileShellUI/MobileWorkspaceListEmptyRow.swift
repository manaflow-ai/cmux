#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var retryFailure: String?

    private enum RetryError: Error {
        case timedOut
    }

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
                    let task = Task { @MainActor in
                        defer {
                            isRetrying = false
                            retryTask = nil
                        }
                        do {
                            try await withThrowingTaskGroup(of: Void.self) { group in
                                defer { group.cancelAll() }
                                group.addTask {
                                    await retry()
                                }
                                group.addTask {
                                    try await ContinuousClock().sleep(for: .seconds(15))
                                    throw RetryError.timedOut
                                }
                                _ = try await group.next()
                            }
                        } catch is CancellationError {
                            // Disappearing rows cancel an in-flight refresh.
                        } catch {
                            retryFailure = L10n.string(
                                "mobile.workspaces.empty.retryFailed",
                                defaultValue: "Couldn’t refresh. Try again."
                            )
                        }
                    }
                    retryTask = task
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
            retryTask = nil
        }
    }
}
#endif
