#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohPrivatePathTestButton: View {
    let presentation: MobileIrohPrivatePathProbePresentation
    let isAnotherProbeInFlight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch presentation {
            case .idle:
                Text(L10n.string(
                    "mobile.iroh.private.test.action",
                    defaultValue: "Test"
                ))
            case .testing:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string(
                        "mobile.iroh.private.test.testing",
                        defaultValue: "Testing"
                    ))
                }
            case let .finished(.reachable(latencyMilliseconds)):
                Label(
                    String(
                        format: L10n.string(
                            "mobile.iroh.private.test.reachable",
                            defaultValue: "%lld ms"
                        ),
                        Int64(latencyMilliseconds)
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case let .finished(.unreachable(failure)):
                Label(failureText(failure), systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(presentation == .testing || isAnotherProbeInFlight)
    }

    private func failureText(
        _ failure: CmxIrohPrivatePathProbeFailure
    ) -> String {
        switch failure {
        case .noRoute:
            L10n.string(
                "mobile.iroh.private.test.failure.noRoute",
                defaultValue: "No route"
            )
        case .timedOut:
            L10n.string(
                "mobile.iroh.private.test.failure.timedOut",
                defaultValue: "Timed out"
            )
        case .macNotListening:
            L10n.string(
                "mobile.iroh.private.test.failure.macNotListening",
                defaultValue: "Mac not listening"
            )
        case .stalePort:
            L10n.string(
                "mobile.iroh.private.test.failure.stalePort",
                defaultValue: "Stale port"
            )
        case .wrongPeer:
            L10n.string(
                "mobile.iroh.private.test.failure.wrongPeer",
                defaultValue: "Wrong Mac answered"
            )
        case .unavailable:
            L10n.string(
                "mobile.iroh.private.test.failure.unavailable",
                defaultValue: "Unavailable"
            )
        case .busy:
            L10n.string(
                "mobile.iroh.private.test.failure.busy",
                defaultValue: "Another test is running"
            )
        }
    }
}
#endif
