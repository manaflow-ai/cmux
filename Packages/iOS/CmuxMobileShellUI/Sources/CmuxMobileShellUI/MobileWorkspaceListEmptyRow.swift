#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?

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
                    isRetrying = true
                    retryTask = Task { @MainActor in
                        defer {
                            retryTask = nil
                            isRetrying = false
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
            isRetrying = false
        }
    }
}
#endif
