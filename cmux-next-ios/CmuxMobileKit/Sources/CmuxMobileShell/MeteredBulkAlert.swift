#if os(iOS)
import CmuxMobileLinkFFI
import SwiftUI
import UIKit

/// Presents the link's pending upload decision, including over a file picker or sheet.
@MainActor
struct MeteredBulkAlert: ViewModifier {
    @State private var scene: UIWindowScene?
    @State private var alertWindow: UIWindow?

    func body(content: Content) -> some View {
        content
            .background(SceneReader { scene = $0 })
            .task(id: scene) {
                guard let scene else { return }
                var state = meteredBulkState()
                while !Task.isCancelled {
                    update(state, in: scene)
                    state = await meteredBulkChanged(afterRevision: state.revision)
                }
            }
            .onDisappear { close() }
    }

    private func update(_ state: MeteredBulkState, in scene: UIWindowScene) {
        guard state.metered, !state.consent, !state.deferred, state.waitingBytes > 0 else {
            close()
            return
        }
        // Dropping/replacing the window also dismisses a prompt from an older batch.
        close()
        let presenter = UIViewController()
        presenter.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .clear
        window.rootViewController = presenter
        window.windowLevel = .alert // App Lock covers this window too.
        window.isHidden = false
        alertWindow = window
        let alert = Self.controller(waitingBytes: state.waitingBytes) {
            guard meteredBulkState().revision == state.revision else { return }
            setMeteredBulkConsent(consent: true)
        } wait: {
            guard meteredBulkState().revision == state.revision else { return }
            deferMeteredBulk()
        }
        presenter.present(alert, animated: true)
    }

    private func close() {
        alertWindow?.isHidden = true
        alertWindow = nil
    }

    static func controller(waitingBytes: UInt64, send: @escaping () -> Void, wait: @escaping () -> Void) -> UIAlertController {
        let megabytes = (Double(waitingBytes) / 1_000_000).formatted(.number.precision(.significantDigits(1...3)))
        let format = String(localized: "mobile.upload.metered.title", defaultValue: "Send %@ MB over cellular?", bundle: .module)
        let title = String(format: format, megabytes)
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let sendTitle = String(localized: "mobile.upload.metered.send", defaultValue: "Send", bundle: .module)
        let waitTitle = String(localized: "mobile.upload.metered.wait", defaultValue: "Wait for Wi-Fi", bundle: .module)
        alert.addAction(UIAlertAction(title: sendTitle, style: .default) { _ in send() })
        alert.addAction(UIAlertAction(title: waitTitle, style: .cancel) { _ in wait() })
        return alert
    }
}
#endif
