import CmuxCloud
import SwiftUI

/// Main's Cloud toolbar status, driven by values from the combined Cloud/Devices panel.
/// Its row exists only while there is something to say; plan usage lives on the
/// Cloud Machines header instead.
struct MachinesCloudStatus: View {
    let activeOperation: String?
    /// The machine-list status, only while cached machines stay on screen.
    let listStatus: MachineListStatus?
    /// Dismissal identity only; upstream details are never presented.
    let listError: String?
    let treeError: String?
    let onDismissStale: (String) -> Void
    let onDismissTreeError: (String) -> Void
    /// Runs the fix the status names. The notice and the empty state route the
    /// same three actions through it, so the toolbar row is not a dead end.
    let performListStatusAction: (MachineListStatusPresentation.Action) -> Void

    /// The same safe recovery copy is used for text, hover help and copying.
    var treeErrorMessage: String {
        String(localized: "cloud.operation.failedAction", defaultValue: "This operation did not complete. Check the machine state before you try it again.")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if listStatus != nil || treeError != nil {
                HStack(spacing: 6) {
                    persistentMessage
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
                .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
            }
            if let activeOperation {
                // Opening a Cloud surface is usually fast enough that a status row
                // would only flash. Keep the progress affordance at the status row's
                // origin, but give it no layout height so the tree never jumps.
                Color.clear
                    .frame(maxWidth: .infinity, height: 0)
                    .overlay(alignment: .topLeading) {
                        operationMessage(activeOperation)
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }
            }
        }
    }

    private func operationMessage(_ operation: String) -> some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(operation)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var persistentMessage: some View {
        if let listStatus {
            MachinesListStatusToolbarRow(
                status: listStatus,
                dismissalSignature: listError,
                onDismiss: onDismissStale,
                perform: performListStatusAction
            )
        } else if let error = treeError {
            let safeMessage = treeErrorMessage
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                Text(safeMessage)
                    .cmuxFont(size: 11)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                CloudBannerDismissButton { onDismissTreeError(error) }
            }
            .foregroundColor(.orange.opacity(0.9))
            .help(safeMessage)
            .cloudErrorCopyMenu(safeMessage)
        }
    }
}

extension MachinesPanelView {
    func performListStatusAction(_ action: MachineListStatusPresentation.Action) {
        switch action {
        case .retry:
            viewModel.recoverList()
        case .signInAgain:
            guard let accountFlow = AppDelegate.shared?.auth?.accountFlow else { return }
            Task { await accountFlow.signOut() }
        case .upgrade:
            ProUpgradePresenter.present(source: .machinesPanelRequiresPro)
        }
    }
}
