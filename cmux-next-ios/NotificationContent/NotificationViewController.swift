import CmuxMobileNotifications
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The long-press view of every cmux notification (verify/rich-push.md
/// "Expanded view"). It has no link to the Mac: what it sends goes to the
/// App Group outbox, and the app (opened by `performNotificationDefaultAction`)
/// sends it over that Mac's link, asking Face ID for an answer or an Allow.
final class NotificationViewController: UIViewController, @MainActor UNNotificationContentExtension {
    private let model = NotificationContentModel()
    private var host: UIHostingController<NotificationContentView>?
    private var loading: Task<Void, Never>?

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

    // UserNotificationsUI calls the extension on the main thread (an isolated conformance).
    func didReceive(_ notification: UNNotification) {
        // Opened again from its box; an unsealed one from a Mac that seals, or a
        // stale one, shows without rows, Submit or composer (PR B security review H1).
        let content = notification.request.content
        let verdict = PushTrustGate.current().verdict(
            userInfo: content.userInfo,
            shown: PushTrustGate.Shown(title: content.title, subtitle: content.subtitle, body: content.body,
                                       category: content.categoryIdentifier))
        let (payload, actionable): (PushPayload?, Bool) = switch verdict {
        case .trusted(let p): (p, true)
        case .openOnly(let p): (p, false)
        case .refused: (nil, false)
        }
        model.actionable = actionable
        // The push shows at once; the App Group's outbox and snapshot join it once resolved.
        model.load(payload: payload, group: nil)
        // The App Group (outbox, chat snapshot) and the shared Require Face ID
        // choice are read off the main thread. A build signed without the
        // App Group shows the push alone and offers "Open in app" only.
        loading?.cancel()
        loading = Task { [weak self] in
            let (group, preference) = await Task.detached(priority: .userInitiated) { () -> (PushAppGroup?, Bool) in
                let group = await PushAppGroup.resolved()
                return (group, PushSharedPreference.live(group: group).requireFaceID)
            }.value
            guard let self, !Task.isCancelled else { return }
            if group != nil { self.model.load(payload: payload, group: group) }
            // The notification's own buttons: a question's options, the permission's offers.
            // With previews off the static buttons stay (review L1); Require Face ID opens the app (L2).
            if let payload, actionable {
                let actions = PushActions(requireFaceID: preference).extensionActions(for: payload)
                if !actions.isEmpty { self.extensionContext?.notificationActions = actions }
            }
        }
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
