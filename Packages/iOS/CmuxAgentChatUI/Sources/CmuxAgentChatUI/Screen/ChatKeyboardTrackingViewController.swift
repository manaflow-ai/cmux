#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

@MainActor
final class ChatKeyboardTrackingViewController<Transcript: View, Composer: View>: UIViewController, UIGestureRecognizerDelegate {
    var transcriptView: Transcript {
        get { transcriptHostingController.rootView }
        set { transcriptHostingController.rootView = newValue }
    }

    var composerView: Composer {
        get { composerHostingController.rootView }
        set { composerHostingController.rootView = newValue }
    }

    var showsComposer: Bool {
        didSet { updateComposerVisibility() }
    }

    private let transcriptHostingController: UIHostingController<Transcript>
    private let composerHostingController: UIHostingController<Composer>
    private typealias ScrollSnapshot = (scrollView: ChatTranscriptUITableView, snapshot: MobileScrollViewportSnapshot)
    private var composerZeroHeightConstraint: NSLayoutConstraint?
    private var activeKeyboardScrollSnapshots: [ScrollSnapshot] = []
    private var isRestoringKeyboardViewport = false
    private weak var installedWindow: UIWindow?

    private lazy var dismissTapRecognizer: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDismissTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    init(transcriptView: Transcript, composerView: Composer, showsComposer: Bool) {
        transcriptHostingController = UIHostingController(rootView: transcriptView)
        composerHostingController = UIHostingController(rootView: composerView)
        self.showsComposer = showsComposer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used in storyboards") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        addChild(transcriptHostingController)
        transcriptHostingController.view.backgroundColor = .clear
        transcriptHostingController.safeAreaRegions = .container
        transcriptHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptHostingController.view)

        addChild(composerHostingController)
        composerHostingController.view.backgroundColor = .clear
        composerHostingController.safeAreaRegions = .container
        composerHostingController.sizingOptions = [.intrinsicContentSize]
        composerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        composerHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        composerHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(composerHostingController.view)

        let zeroHeight = composerHostingController.view.heightAnchor.constraint(equalToConstant: 0)
        composerZeroHeightConstraint = zeroHeight

        NSLayoutConstraint.activate([
            transcriptHostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcriptHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptHostingController.view.bottomAnchor.constraint(equalTo: composerHostingController.view.topAnchor),

            composerHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerHostingController.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        transcriptHostingController.didMove(toParent: self)
        composerHostingController.didMove(toParent: self)
        updateComposerVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installDismissTapIfNeeded()
        restoreKeyboardViewports(activeKeyboardScrollSnapshots)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        installedWindow?.removeGestureRecognizer(dismissTapRecognizer)
        installedWindow = nil
    }

    private func installDismissTapIfNeeded() {
        if view.window !== installedWindow {
            installedWindow?.removeGestureRecognizer(dismissTapRecognizer)
            installedWindow = nil
        }
        guard installedWindow == nil, let window = view.window else { return }
        window.addGestureRecognizer(dismissTapRecognizer)
        installedWindow = window
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let transition = MobileKeyboardTransition(notification: notification) else { return }
        let scrollSnapshots = activeKeyboardScrollSnapshots.isEmpty
            ? trackedScrollSnapshots()
            : activeKeyboardScrollSnapshots
        activeKeyboardScrollSnapshots = scrollSnapshots
        transition.animate {
            self.apply(preserving: scrollSnapshots)
        } completion: { _ in
            self.apply(preserving: scrollSnapshots)
            self.activeKeyboardScrollSnapshots = []
        }
    }

    private func apply(preserving scrollSnapshots: [ScrollSnapshot] = []) {
        view.window?.setNeedsLayout()
        view.setNeedsLayout()
        view.window?.layoutIfNeeded()
        view.layoutIfNeeded()
        transcriptHostingController.view.layoutIfNeeded()
        composerHostingController.view.layoutIfNeeded()
        restoreKeyboardViewports(scrollSnapshots)
    }

    private func restoreKeyboardViewports(_ scrollSnapshots: [ScrollSnapshot]) {
        guard !scrollSnapshots.isEmpty, !isRestoringKeyboardViewport else { return }
        isRestoringKeyboardViewport = true
        defer { isRestoringKeyboardViewport = false }
        for (scrollView, snapshot) in scrollSnapshots {
            scrollView.restoreKeyboardViewport(snapshot)
        }
    }

    private func trackedScrollSnapshots() -> [ScrollSnapshot] {
        trackedTranscriptTables(in: transcriptHostingController.view).map { tableView in
            (scrollView: tableView, snapshot: tableView.keyboardViewportSnapshot())
        }
    }

    private func updateComposerVisibility() {
        guard isViewLoaded else { return }
        composerHostingController.view.isHidden = !showsComposer
        composerZeroHeightConstraint?.isActive = !showsComposer
        view.setNeedsLayout()
    }

    @objc private func handleDismissTap() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func trackedTranscriptTables(in view: UIView) -> [ChatTranscriptUITableView] {
        var tables: [ChatTranscriptUITableView] = []
        if let table = view as? ChatTranscriptUITableView {
            tables.append(table)
        }
        for subview in view.subviews {
            tables.append(contentsOf: trackedTranscriptTables(in: subview))
        }
        return tables
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let window = view.window else { return false }
        let point = touch.location(in: window)
        let transcriptFrame = transcriptHostingController.view.convert(
            transcriptHostingController.view.bounds,
            to: window
        )
        guard transcriptFrame.contains(point) else { return false }
        let composerFrame = composerHostingController.view.convert(
            composerHostingController.view.bounds,
            to: window
        )
        return !composerFrame.contains(point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
