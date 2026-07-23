#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

struct AccountComputerRecoveryButton: View {
    var isProminent = false
    let mode: MobileAccountComputerRecoveryMode
    let isRecovering: Bool
    let recover: @MainActor () async -> MobileAccountComputerRecoveryResult
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
        Button(action: recoverAccountComputer) {
            Label {
                Text(isRecoveryInProgress ? recoveringTitle : title)
            } icon: {
                if isRecoveryInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
        }
        .disabled(isRecoveryInProgress)
        .accessibilityIdentifier("MobileAccountComputerRecoveryButton")
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

    private var isRecoveryInProgress: Bool {
        isRecovering || recoveryTask != nil
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented { alertMessage = nil }
            }
        )
    }

    private func recoverAccountComputer() {
        guard !isRecoveryInProgress else { return }
        alertMessage = nil
        recoveryTask = Task { @MainActor in
            defer { recoveryTask = nil }
            let result = await recover()
            guard !Task.isCancelled else { return }
            switch result {
            case .recovered, .alreadyInProgress, .staleScope:
                break
            case .notFound:
                await reloadAfterFailure()
                guard !Task.isCancelled else { return }
                alertMessage = failureMessage
            }
        }
    }

    private func cancelRecoveryTask() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private var recoveringTitle: String {
        switch mode {
        case .recoverDeletedComputer:
            L10n.string(
                "mobile.computers.recoveringDeleted",
                defaultValue: "Recovering Deleted Computer..."
            )
        case .findAccountComputer, .unavailable:
            L10n.string(
                "mobile.computers.findingAccount",
                defaultValue: "Searching Account..."
            )
        }
    }

    private var title: String {
        switch mode {
        case .recoverDeletedComputer:
            L10n.string(
                "mobile.computers.recoverDeleted",
                defaultValue: "Recover Deleted Computer"
            )
        case .findAccountComputer, .unavailable:
            L10n.string(
                "mobile.computers.findAccount",
                defaultValue: "Find Account Computer"
            )
        }
    }

    private var failureTitle: String {
        L10n.string(
            "mobile.computers.recoverFailedTitle",
            defaultValue: "Couldn't recover computer"
        )
    }

    private var failureMessage: String {
        switch mode {
        case .recoverDeletedComputer:
            L10n.string(
                "mobile.computers.recoverFailedMessage",
                defaultValue: "No deleted computer was recovered. Open cmux on the Mac, sign in to this same account, and try again."
            )
        case .findAccountComputer, .unavailable:
            L10n.string(
                "mobile.computers.findAccountFailedMessage",
                defaultValue: "No account computer was found. Open cmux on the Mac, sign in to this same account, and try again."
            )
        }
    }
}

@MainActor
struct AccountComputerRecoveryFooter: View {
    let mode: MobileAccountComputerRecoveryMode

    var body: some View {
        Text(footer)
    }

    private var footer: String {
        switch mode {
        case .recoverDeletedComputer:
            L10n.string(
                "mobile.computers.recoverDeletedFooter",
                defaultValue: "Deleted computers stay hidden on this phone. To recover one, open cmux on that Mac, sign in to this same account, then tap Recover Deleted Computer."
            )
        case .findAccountComputer, .unavailable:
            L10n.string(
                "mobile.computers.findAccountFooter",
                defaultValue: "Open cmux on the Mac and sign in to this same account. Account recovery does not require a QR code."
            )
        }
    }
}
#endif
