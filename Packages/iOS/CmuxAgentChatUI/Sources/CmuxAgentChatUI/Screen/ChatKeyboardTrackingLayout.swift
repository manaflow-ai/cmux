#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Moves the chat transcript/composer stack with the software keyboard.
///
/// SwiftUI's default keyboard avoidance can translate a focused field without
/// changing the embedded `UITableView`'s frame. This modifier hosts the chat
/// root in UIKit and animates the hosted view's bottom constraint from
/// `UIKeyboardWillChangeFrame`, so the transcript's actual bounds shrink while
/// the composer rides the keyboard edge.
struct ChatKeyboardTrackingLayout: ViewModifier {
    func body(content: Content) -> some View {
        ChatKeyboardTrackingContainer(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct ChatKeyboardTrackingContainer<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> ChatKeyboardTrackingViewController<Content> {
        ChatKeyboardTrackingViewController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: ChatKeyboardTrackingViewController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}

@MainActor
private final class ChatKeyboardTrackingViewController<Content: View>: UIViewController {
    var rootView: Content {
        get { hostingController.rootView }
        set { hostingController.rootView = newValue }
    }

    private let hostingController: UIHostingController<Content>
    private var hostedBottomConstraint: NSLayoutConstraint?
    private var currentReservation: CGFloat = 0
    private var latestKeyboardEndFrame: CGRect?

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
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

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)

        let bottomConstraint = hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        hostedBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
        hostingController.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let latestKeyboardEndFrame else { return }
        let reservation = keyboardReservation(forScreenFrame: latestKeyboardEndFrame)
        if abs(reservation - currentReservation) > 0.5 {
            apply(reservation: reservation)
        }
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let transition = MobileKeyboardTransition(notification: notification) else { return }
        latestKeyboardEndFrame = transition.endFrame
        let reservation = keyboardReservation(forScreenFrame: transition.endFrame)
        guard abs(reservation - currentReservation) > 0.5 else { return }
        transition.animate {
            self.apply(reservation: reservation)
        }
    }

    private func apply(reservation: CGFloat) {
        currentReservation = reservation
        hostedBottomConstraint?.constant = -reservation
        view.layoutIfNeeded()
        view.window?.layoutIfNeeded()
    }

    private func keyboardReservation(forScreenFrame screenFrame: CGRect) -> CGFloat {
        guard let window = view.window else { return 0 }
        let keyboardFrame = window.convert(screenFrame, from: nil)
        let viewFrame = view.convert(view.bounds, to: window)
        let intersection = viewFrame.intersection(keyboardFrame)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.height)
    }
}
#endif
