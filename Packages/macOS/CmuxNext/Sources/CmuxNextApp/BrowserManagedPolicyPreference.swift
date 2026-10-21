import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import Observation

/// The organization's Chrome enterprise policies reach both engines
/// (plans/cmux-next/chrome-enterprise-policy-DESIGN.md): Chromium reads
/// Chrome's policy domain itself from its start, and WebKit tabs follow the
/// managed `URLBlocklist` / `URLAllowlist` (Chrome's domain under cmux's
/// browser domain, read by the settings controller) on every load.
@MainActor
enum BrowserManagedPolicyPreference {
    static func follow(_ settings: SettingsController, webKit: WebKitEngine, cef: CEFEngine) {
        cef.chromePolicyID = {
            ChromePolicyDocument.nativePolicyDomain(cmuxBrowser: CFChromePolicyReader(domain: ChromePolicyDocument.cmuxDomain).read())
        }
        // task-owner: app-lifetime observation of the managed policy; settings and engine weak.
        Task { [weak settings, weak webKit] in
            guard let settings else { return }
            for await policy in ObservationStream({ settings.managedPolicy }) {
                guard let webKit else { return }
                let filter = BrowserURLFilter(managedPolicy: policy)
                if webKit.urlFilter != filter { webKit.urlFilter = filter }
            }
        }
    }
}
