import AppKit
import Foundation

/// The verbs a pending machine row offers: retry a failed create, show the
/// CLI's output, and dismiss the row. Bound above the outline like every
/// other closure bundle (snapshot-boundary rule); rows never see the
/// coordinator.
struct MachineCreateRowActions {
    let retry: @MainActor (UUID) -> Void
    let dismiss: @MainActor (UUID) -> Void
    let showFailure: @MainActor (UUID) -> Void
    let copyFailure: @MainActor (UUID) -> Void

    /// Rows with nothing behind them (previews, tests).
    static let inert = MachineCreateRowActions(
        retry: { _ in },
        dismiss: { _ in },
        showFailure: { _ in },
        copyFailure: { _ in }
    )

    @MainActor
    static func bound(coordinator: MachineCreateCoordinator) -> MachineCreateRowActions {
        MachineCreateRowActions(
            retry: { [weak coordinator] id in
                coordinator?.retry(id)
            },
            dismiss: { [weak coordinator] id in
                coordinator?.dismiss(id)
            },
            showFailure: { [weak coordinator] id in
                guard let operation = coordinator?.operation(id: id), let output = operation.failureOutput else { return }
                presentFailure(operation: operation, output: output)
            },
            copyFailure: { [weak coordinator] id in
                guard let output = coordinator?.operation(id: id)?.failureOutput else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }
        )
    }

    /// The failure in the house alert style: headline fixed, the CLI transcript
    /// in the scrollable details region. Attached to the key window so it moves
    /// with it; this is a person-initiated look at an error, not a modal the
    /// create imposes.
    @MainActor
    private static func presentFailure(operation: MachineCreateOperation, output: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = operation.request.failureLabel
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        let lead = String(
            format: String(localized: "machines.pending.failure.lead", defaultValue: "%@ did not get created. The command reported:"),
            operation.request.displayName
        )
        let content = CmuxAlertContent(flattenedText: "\(lead)\n\n\(output)", separatingScrollableDetails: output)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        content.apply(to: alert, presentingWindow: window)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }
}
