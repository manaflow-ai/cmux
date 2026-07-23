#if os(iOS)
import CmuxMobileSupport
import SwiftUI

@MainActor
private enum DeletedComputerRecoveryCopy {
    static var recoveringTitle: String {
        L10n.string(
            "mobile.computers.recoveringDeleted",
            defaultValue: "Recovering Deleted Computer..."
        )
    }

    static var title: String {
        L10n.string(
            "mobile.computers.recoverDeleted",
            defaultValue: "Recover Deleted Computer"
        )
    }

    static var footer: String {
        L10n.string(
            "mobile.computers.recoverDeletedFooter",
            defaultValue: "Deleted computers stay hidden on this phone. To recover one, open cmux on that Mac, sign in to this same account, then tap Recover Deleted Computer."
        )
    }

    static var failureTitle: String {
        L10n.string(
            "mobile.computers.recoverFailedTitle",
            defaultValue: "Couldn't recover computer"
        )
    }

    static var failureMessage: String {
        L10n.string(
            "mobile.computers.recoverFailedMessage",
            defaultValue: "No deleted computer was recovered. Open cmux on the Mac, sign in to this same account, and try again."
        )
    }
}

struct DeletedComputerRecoveryButton: View {
    var isProminent = false
    let recover: @MainActor () async -> Bool
    let reload: @MainActor () async -> Void

    @State private var isRecovering = false
    @State private var alertMessage: String?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var recoveryAttemptID = 0

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
                Text(isRecovering ? DeletedComputerRecoveryCopy.recoveringTitle : DeletedComputerRecoveryCopy.title)
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
            DeletedComputerRecoveryCopy.failureTitle,
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
        guard !isRecovering else { return }
        isRecovering = true
        alertMessage = nil
        recoveryAttemptID += 1
        let attemptID = recoveryAttemptID
        recoveryTask = Task { @MainActor in
            let recovered = await recover()
            guard isCurrentRecoveryAttempt(attemptID) else { return }
            await reload()
            guard isCurrentRecoveryAttempt(attemptID) else { return }
            isRecovering = false
            recoveryTask = nil
            if !recovered {
                alertMessage = DeletedComputerRecoveryCopy.failureMessage
            }
        }
    }

    private func cancelRecoveryTask() {
        recoveryAttemptID += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
    }

    private func isCurrentRecoveryAttempt(_ attemptID: Int) -> Bool {
        !Task.isCancelled && recoveryAttemptID == attemptID
    }
}

@MainActor
struct DeletedComputerRecoveryFooter: View {
    var body: some View {
        Text(DeletedComputerRecoveryCopy.footer)
    }
}
#endif
