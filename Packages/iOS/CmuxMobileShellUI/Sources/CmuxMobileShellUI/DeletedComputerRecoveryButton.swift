#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct DeletedComputerRecoveryButton: View {
    var isProminent = false
    let isRecovering: Bool
    let recover: @MainActor () async -> Bool
    let reloadAfterFailure: @MainActor () async -> Void

    @State private var alertMessage: String?

    @ViewBuilder
    var body: some View {
        if isProminent {
            recoveryButton
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        } else {
            recoveryButton
        }
    }

    private var recoveryButton: some View {
        Button(action: recoverDeletedComputer) {
            Label {
                Text(isRecovering ? recoveringTitle : title)
            } icon: {
                if isRecovering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
        }
        .disabled(isRecovering)
        .accessibilityIdentifier("MobileRecoverDeletedComputerButton")
        .alert(
            failureTitle,
            isPresented: alertPresented
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented { alertMessage = nil }
            }
        )
    }

    private func recoverDeletedComputer() {
        guard !isRecovering else { return }
        alertMessage = nil
        Task { @MainActor in
            let recovered = await recover()
            if !recovered {
                await reloadAfterFailure()
                alertMessage = failureMessage
            }
        }
    }

    private var recoveringTitle: String {
        L10n.string(
            "mobile.computers.recoveringDeleted",
            defaultValue: "Recovering Deleted Computer..."
        )
    }

    private var title: String {
        L10n.string(
            "mobile.computers.recoverDeleted",
            defaultValue: "Recover Deleted Computer"
        )
    }

    private var failureTitle: String {
        L10n.string(
            "mobile.computers.recoverFailedTitle",
            defaultValue: "Couldn't recover computer"
        )
    }

    private var failureMessage: String {
        L10n.string(
            "mobile.computers.recoverFailedMessage",
            defaultValue: "No deleted computer was recovered. Open cmux on the Mac, sign in to this same account, and try again."
        )
    }
}

@MainActor
struct DeletedComputerRecoveryFooter: View {
    var body: some View {
        Text(footer)
    }

    private var footer: String {
        L10n.string(
            "mobile.computers.recoverDeletedFooter",
            defaultValue: "Deleted computers stay hidden on this phone. To recover one, open cmux on that Mac, sign in to this same account, then tap Recover Deleted Computer."
        )
    }
}
#endif
