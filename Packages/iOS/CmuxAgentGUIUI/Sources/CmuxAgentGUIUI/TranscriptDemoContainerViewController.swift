#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import UIKit

final class TranscriptDemoContainerViewController: UIViewController {
    private let transcript = TranscriptListViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view)
        transcript.didMove(toParent: self)

        NSLayoutConstraint.activate([
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        transcript.apply(input: input)
    }

    func scrollToBottom() {
        transcript.scrollToBottom()
    }

    func setBottomChromeHeight(_ height: CGFloat) {
        transcript.setBottomChromeHeight(height)
    }
}
#endif
