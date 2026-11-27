#if os(iOS)
import CmuxMobileModel
import Combine
import SwiftUI
import UIKit

/// Shake to report a bug: one shake anywhere in the app asks "Report a bug?", and one tap copies this
/// launch's log (Settings > Copy Logs, PhoneLogs) and opens the bug report form (Settings > Send feedback,
/// FeedbackFormLink) for the log to be pasted in. Leo, 2026-11-27: "and then idk what im supposed to be able
/// to do to test and verify on my end either like faster dev loops and testflight or anything".
public extension View {
    /// The shake-to-report dialog over this view (RootView puts it over the whole shell).
    func shakeToReportBug() -> some View { modifier(ShakeToReport()) }
}

extension Notification.Name {
    /// The phone was shaken (UIWindow.motionEnded): ShakeToReport's trigger.
    static let cmuxMobileDeviceDidShake = Notification.Name("dev.cmux.mobile.deviceDidShake")
}

extension UIWindow {
    /// A shake ends at the key window when no responder above it takes it (a text view's Undo still does).
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .cmuxMobileDeviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

struct ShakeToReport: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cmuxMobileDeviceDidShake)) { _ in asking = true }
            #if DEBUG
            // Screenshot rig (cmux-next-ios-sim.sh shots, settings=-cmux-mobile-shake): a simulator cannot shake.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-cmux-mobile-shake") else { return }
                try? await Task.sleep(for: .seconds(2))
                asking = true
            }
            #endif
            .confirmationDialog(
                String(localized: "mobile.shakeReport.title", defaultValue: "Report a bug?", bundle: .module),
                isPresented: $asking, titleVisibility: .visible
            ) {
                Button(String(localized: "mobile.shakeReport.report", defaultValue: "Copy Logs and Open Report",
                              bundle: .module)) { report() }
                    .accessibilityIdentifier("shakeReport.report")
                Button(String(localized: "mobile.shakeReport.cancel", defaultValue: "Cancel", bundle: .module),
                       role: .cancel) {}
            } message: {
                Text(String(localized: "mobile.shakeReport.message",
                            defaultValue: "This launch's log goes on the clipboard. Paste it into the form's Additional context.",
                            bundle: .module))
            }
    }

    private func report() {
        Task {
            let text = await Task.detached(priority: .userInitiated) { PhoneLogs.report() }.value
            UIPasteboard.general.string = text
            let info = Bundle.main.infoDictionary ?? [:]
            openURL(FeedbackFormLink.url(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
                build: info["CFBundleVersion"] as? String ?? "?",
                osVersion: UIDevice.current.systemVersion
            ))
        }
    }
}
#endif
