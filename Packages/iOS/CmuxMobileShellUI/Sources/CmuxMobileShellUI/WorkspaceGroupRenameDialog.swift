#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Compact group-rename alert shared by SwiftUI and UIKit-backed list actions.
extension View {
    func workspaceGroupRenameDialog(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        onSave: @escaping (String) -> Void
    ) -> some View {
        background {
            WorkspaceGroupRenameAlertPresenter(
                isPresented: isPresented,
                text: text,
                onSave: onSave
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

/// SwiftUI alert actions do not consistently refresh dynamic disabled state.
/// UIKit owns the native alert here so whitespace validation remains live while
/// preserving the compact system-alert presentation.
private struct WorkspaceGroupRenameAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var text: String
    let onSave: (String) -> Void

    func makeUIViewController(context: Context) -> WorkspaceGroupRenameAlertViewController {
        WorkspaceGroupRenameAlertViewController()
    }

    func updateUIViewController(
        _ controller: WorkspaceGroupRenameAlertViewController,
        context: Context
    ) {
        controller.update(
            isPresented: isPresented,
            text: text,
            setPresented: { isPresented = $0 },
            setText: { text = $0 },
            onSave: onSave
        )
    }

    static func dismantleUIViewController(
        _ controller: WorkspaceGroupRenameAlertViewController,
        coordinator: Void
    ) {
        controller.dismissAlert()
    }
}

@MainActor
private final class WorkspaceGroupRenameAlertViewController: UIViewController {
    private var alertController: UIAlertController?
    private var pendingPresentation = false
    private var currentText = ""
    private var setPresented: ((Bool) -> Void)?
    private var setText: ((String) -> Void)?
    private var onSave: ((String) -> Void)?

    override func loadView() {
        view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentAlertIfReady()
    }

    func update(
        isPresented: Bool,
        text: String,
        setPresented: @escaping (Bool) -> Void,
        setText: @escaping (String) -> Void,
        onSave: @escaping (String) -> Void
    ) {
        currentText = text
        self.setPresented = setPresented
        self.setText = setText
        self.onSave = onSave
        pendingPresentation = isPresented

        if isPresented {
            if let field = alertController?.textFields?.first,
               field.text != text,
               !field.isFirstResponder {
                field.text = text
                updateSaveAvailability(for: text)
            }
            presentAlertIfReady()
        } else {
            dismissAlert()
        }
    }

    func dismissAlert() {
        pendingPresentation = false
        guard let alertController else { return }
        self.alertController = nil
        alertController.dismiss(animated: true)
    }

    private func presentAlertIfReady() {
        guard pendingPresentation,
              alertController == nil,
              viewIfLoaded?.window != nil,
              presentedViewController == nil else { return }

        let alert = UIAlertController(
            title: L10n.string(
                "mobile.workspaceGroup.rename.title",
                defaultValue: "Rename Group"
            ),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            guard let self else { return }
            field.text = currentText
            field.placeholder = L10n.string(
                "mobile.workspaceGroup.rename.placeholder",
                defaultValue: "Group name"
            )
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "WorkspaceGroupRenameField"
            field.addTarget(
                self,
                action: #selector(renameTextChanged(_:)),
                for: .editingChanged
            )
        }
        let save = UIAlertAction(
            title: L10n.string("mobile.common.save", defaultValue: "Save"),
            style: .default
        ) { [weak self] _ in
            self?.saveRename()
        }
        alert.addAction(save)
        alert.addAction(
            UIAlertAction(
                title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                style: .cancel
            ) { [weak self] _ in
                self?.finishPresentation()
            }
        )
        alertController = alert
        updateSaveAvailability(for: currentText)
        present(alert, animated: true)
    }

    @objc private func renameTextChanged(_ field: UITextField) {
        let value = field.text ?? ""
        currentText = value
        setText?(value)
        updateSaveAvailability(for: value)
    }

    private func updateSaveAvailability(for value: String) {
        alertController?.actions.first?.isEnabled = !value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func saveRename() {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            updateSaveAvailability(for: currentText)
            return
        }
        let completion = onSave
        // The presentation binding also owns the pending group ID. Deliver the
        // rename before clearing it so the shared list action keeps its target.
        completion?(trimmed)
        finishPresentation()
    }

    private func finishPresentation() {
        pendingPresentation = false
        alertController = nil
        setPresented?(false)
    }
}
#endif
