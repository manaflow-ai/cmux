import CmuxMobileNotifications
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The long-press view of every cmux notification (verify/rich-push.md
/// "Expanded view"). It has no link to the Mac: what it sends goes to the
/// App Group outbox, and the app (opened by `performNotificationDefaultAction`)
/// sends it over that Mac's link, asking Face ID for an answer or an Allow.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = NotificationContentModel()
    private var host: UIHostingController<NotificationContentView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: NotificationContentView(model: model))
        host.view.backgroundColor = .clear
        host.sizingOptions = .preferredContentSize
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
        model.send = { [weak self] action in self?.send(action) }
        model.openApp = { [weak self] in self?.extensionContext?.performNotificationDefaultAction() }
        model.presentPicker = { [weak self] picker in self?.present(picker, animated: true) }
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        preferredContentSize = CGSize(width: view.bounds.width, height: container.preferredContentSize.height)
    }

    func didReceive(_ notification: UNNotification) {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        model.load(payload: payload, group: PushAppGroup.current())
        // The notification's own buttons: a question's options, the permission's offers.
        if let payload { extensionContext?.notificationActions = PushActions().actions(for: payload) }
    }

    /// Buttons go on to the app delegate, which owns delivery (and Face ID).
    func didReceive(_ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        completion(.dismissAndForwardAction)
    }

    /// A row, Submit or the composer: hand the reply to the app, then open it on the chat.
    private func send(_ action: PushReply.Action) {
        guard let payload = model.payload, let reply = PushReply(payload: payload, action: action) else {
            extensionContext?.performNotificationDefaultAction()
            return
        }
        do {
            try model.outbox?.put(reply)
            model.sent = true
        } catch {
            model.failure = String(localized: "Couldn't hand this to cmux. Open the app to answer.")
        }
        extensionContext?.performNotificationDefaultAction()
    }
}
