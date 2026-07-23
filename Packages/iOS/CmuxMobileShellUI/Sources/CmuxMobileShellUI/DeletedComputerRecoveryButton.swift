#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct DeletedComputerRecoveryButton: View {
    var isProminent = false
    let isRecovering: Bool
    let recover: @MainActor () async -> MobileDeletedComputerRecoveryResult
    let reloadAfterFailure: @MainActor () async -> Void

    @State private var alertMessage: String?
    @State private var recoveryTask: Task<Void, Never>?

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
        .onDisappear(perform: cancelRecoveryTask)
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
        guard !isRecovering, recoveryTask == nil else { return }
        alertMessage = nil
        recoveryTask = Task { @MainActor in
            let result = await recover()
            guard !Task.isCancelled else { return }
            switch result {
            case .recovered, .alreadyInProgress:
                break
            case .notFound:
                await reloadAfterFailure()
                guard !Task.isCancelled else { return }
                alertMessage = failureMessage
            }
            recoveryTask = nil
        }
    }

    private func cancelRecoveryTask() {
        recoveryTask?.cancel()
        recoveryTask = nil
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
