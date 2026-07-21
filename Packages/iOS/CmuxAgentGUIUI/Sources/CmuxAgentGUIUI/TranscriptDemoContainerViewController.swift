#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

final class TranscriptDemoContainerViewController: UIViewController {
    let transcript: TranscriptListViewController
    private var currentTheme: AgentGUITheme
    private var composerHost: UIHostingController<TranscriptDemoComposerView>?
    private(set) var composerBottomConstraint: NSLayoutConstraint?

    var composerHostView: UIView? {
        composerHost?.view
    }

    init(theme: AgentGUITheme) {
        transcript = TranscriptListViewController(theme: theme)
        currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(currentTheme.background)
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let composerHost else { return }
        transcript.setBottomChromeHeight(composerHost.view.bounds.height)
    }

    func installComposer(model: TranscriptDemoModel, density: Binding<TranscriptDensity>) {
        guard composerHost == nil else { return }
        loadViewIfNeeded()
        let host = UIHostingController(rootView: TranscriptDemoComposerView(
            model: model,
            density: density,
            jumpToBottom: { [weak self] in
                self?.scrollToBottom()
            }
        ))
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.accessibilityIdentifier = "transcript.demo.composer-host"
        addChild(host)
        view.addSubview(host.view)
        // Keep the Liquid Glass subtree's local bounds fixed. UIKit translates
        // this hosting layer with the same keyboard guide as the transcript;
        // SwiftUI therefore does not rematerialize each glass control while its
        // simultaneously moving backdrop is being sampled.
        let bottomConstraint = host.view.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
        host.didMove(toParent: self)
        composerHost = host
        composerBottomConstraint = bottomConstraint
        transcript.setBottomEdgeElementContainers([host.view])
        view.setNeedsLayout()
    }

    func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        transcript.apply(input: input)
    }

    func apply(theme: AgentGUITheme) {
        currentTheme = theme
        if isViewLoaded {
            view.backgroundColor = UIColor(theme.background)
        }
        transcript.apply(theme: theme)
    }

    func scrollToBottom() {
        transcript.scrollToBottom()
    }

    func setBottomChromeHeight(_ height: CGFloat) {
        transcript.setBottomChromeHeight(height)
    }

    func setDensity(_ density: TranscriptDensity) {
        transcript.setDensity(density)
    }

    func applyActivityPresentation(
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void
    ) {
        transcript.applyActivityPresentation(onShowActivity: onShowActivity)
    }
}
#endif
