#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false

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
            VStack(spacing: 12) {
                if let retry {
                    Button {
                        guard !isRetrying else { return }
                        isRetrying = true
                        Task {
                            defer { isRetrying = false }
                            await retry()
                        }
                    } label: {
                        HStack {
                            if isRetrying {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("MobileWorkspaceEmptySetupGuide")
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceEmptyState")
    }
}
#endif
