#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import UIKit

final class TranscriptDemoContainerViewController: UIViewController {
    private let transcript = TranscriptListViewController()
    private let field = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view)
        transcript.didMove(toParent: self)
        transcript.additionalSafeAreaInsets.bottom = 60

        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .roundedRect
        field.placeholder = AgentGUIL10n.string("agent.demo.fieldPlaceholder", defaultValue: "Demo keyboard field")
        field.returnKeyType = .done
        field.delegate = self
        view.addSubview(field)

        NSLayoutConstraint.activate([
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        transcript.apply(input: input)
    }

    func scrollToBottom() {
        transcript.scrollToBottom()
    }

    func focusDemoField() {
        if field.isFirstResponder {
            field.resignFirstResponder()
        } else {
            field.becomeFirstResponder()
        }
    }
}

extension TranscriptDemoContainerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
#endif
