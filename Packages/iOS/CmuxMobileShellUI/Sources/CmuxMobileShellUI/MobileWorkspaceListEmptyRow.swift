#if os(iOS)
import Foundation
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?
    @State private var retryAttemptID: UUID?

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
                    let attemptID = UUID()
                    retryAttemptID = attemptID
                    retryTask?.cancel()
                    isRetrying = true
                    retryTask = Task { @MainActor in
                        defer {
                            if retryAttemptID == attemptID {
                                retryTask = nil
                                isRetrying = false
                            }
                        }
                        await retry()
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
                if isRetrying {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        retryTask?.cancel()
                        retryAttemptID = nil
                        retryTask = nil
                        isRetrying = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("MobileWorkspaceEmptyRetryCancel")
                }
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
            retryAttemptID = nil
            isRetrying = false
        }
    }
}
#endif
