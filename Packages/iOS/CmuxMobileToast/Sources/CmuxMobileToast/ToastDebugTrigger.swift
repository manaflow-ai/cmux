#if DEBUG && os(iOS)
import Foundation
import notify

/// DEBUG-only remote trigger: presents toasts in a running dev build without
/// touch input, so agents and scripts can exercise the toast layer inside the
/// real app (not just the gallery).
///
/// Drive it on a simulator with two commands:
///
/// ```bash
/// xcrun simctl spawn <udid> defaults write <bundle-id> cmux.debug.toast \
///   '{"style":"success","title":"Optional title","message":"Hello"}'
/// xcrun simctl spawn <udid> notifyutil -p dev.cmux.toast.debug.present
/// ```
///
/// The spec is JSON under the `cmux.debug.toast` defaults key: `style`
/// (info|success|warning|failure), `title`, `message`, `systemImage`,
/// `placement` (top|bottom), `persistent` (bool), `actionLabel`,
/// `coalescingKey`. Posting `dev.cmux.toast.debug.dismiss` clears everything.
/// `ios/scripts/toast-debug.sh` wraps both commands.
@MainActor
final class ToastDebugTrigger {
    static let presentNotification = "dev.cmux.toast.debug.present"
    static let dismissNotification = "dev.cmux.toast.debug.dismiss"
    static let demoNotification = "dev.cmux.toast.debug.demo"
    static let specDefaultsKey = "cmux.debug.toast"

    private let center: ToastCenter
    private var presentToken: Int32 = 0
    private var dismissToken: Int32 = 0
    private var demoToken: Int32 = 0

    init(center: ToastCenter) {
        self.center = center
        var token: Int32 = 0
        notify_register_dispatch(Self.presentNotification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentFromSpec() }
        }
        presentToken = token
        var cancelToken: Int32 = 0
        notify_register_dispatch(Self.dismissNotification, &cancelToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.center.dismissAll() }
        }
        dismissToken = cancelToken
        var demoTok: Int32 = 0
        notify_register_dispatch(Self.demoNotification, &demoTok, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ToastDemo.run(on: self.center)
            }
        }
        demoToken = demoTok
    }

    func invalidate() {
        if presentToken != 0 { notify_cancel(presentToken) }
        if dismissToken != 0 { notify_cancel(dismissToken) }
        if demoToken != 0 { notify_cancel(demoToken) }
        presentToken = 0
        dismissToken = 0
        demoToken = 0
    }

    private struct Spec: Decodable {
        var style: String?
        var title: String?
        var message: String?
        var systemImage: String?
        var placement: String?
        var persistent: Bool?
        var actionLabel: String?
        var coalescingKey: String?
    }

    private func presentFromSpec() {
        let spec = readSpec() ?? Spec()
        let style: Toast.Style = spec.style.flatMap(Toast.Style.init(rawValue:)) ?? .info
        let placement: Toast.Placement = spec.placement.flatMap(Toast.Placement.init(rawValue:)) ?? .top
        center.present(Toast(
            style: style,
            title: spec.title,
            message: spec.message ?? "Debug toast",
            systemImage: spec.systemImage,
            placement: placement,
            autoDismiss: spec.persistent == true ? .never : nil,
            action: spec.actionLabel.map { label in Toast.Action(label: label) {} },
            coalescingKey: spec.coalescingKey
        ))
    }

    private func readSpec() -> Spec? {
        guard let raw = UserDefaults.standard.string(forKey: Self.specDefaultsKey),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Spec.self, from: data)
    }
}
#endif
