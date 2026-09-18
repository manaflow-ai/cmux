#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    let retry: (@Sendable () async -> Void)?
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(
                    L10n.string(
                        "mobile.workspaces.empty.title",
                        defaultValue: "No workspaces yet"
                    )
                )
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                Text(MobilePairingCopy().emptyWorkspaceMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
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
            .padding(.top, 6)
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
