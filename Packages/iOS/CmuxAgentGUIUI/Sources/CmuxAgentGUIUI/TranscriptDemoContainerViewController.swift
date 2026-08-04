#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

final class TranscriptDemoContainerViewController: UIViewController {
    let transcript: TranscriptListViewController
    private var currentTheme: AgentGUITheme
    private var composerHost: UIHostingController<TranscriptDemoComposerView>?
    private(set) var composerBottomConstraint: NSLayoutConstraint?
    private var keyboardIsPresented = false

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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard !keyboardIsPresented else { return }
        updateComposerBottomOffset()
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
        // The keyboard guide already resolves the composer's moving bottom edge.
        // Applying the hosting container's bottom safe area as well would animate
        // that inset inside the translated host and separate the visible controls
        // from the keyboard. Keep the hosted subtree's own geometry fixed.
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.view.accessibilityIdentifier = "transcript.demo.composer-host"
        addChild(host)
        view.addSubview(host.view)
        // Track the keyboard all the way to the physical screen edge. The guide's
        // safe-area fallback otherwise holds the composer above the home indicator
        // for the first and last visible keyboard frames. The resting safe-area
        // offset is applied only outside the keyboard animation below.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let bottomConstraint = host.view.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -view.safeAreaInsets.bottom
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

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard view.window != nil else { return }
        keyboardIsPresented = true
        updateComposerBottomOffset()
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        guard view.window != nil else { return }
        keyboardIsPresented = false
        updateComposerBottomOffset()
    }

    private func updateComposerBottomOffset() {
        guard let composerBottomConstraint else { return }
        let offset = keyboardIsPresented ? 0 : -view.safeAreaInsets.bottom
        guard composerBottomConstraint.constant != offset else { return }
        composerBottomConstraint.constant = offset
        UIView.performWithoutAnimation {
            view.layoutIfNeeded()
        }
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
