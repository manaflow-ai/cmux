import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups
import Observation

/// The organization's Chrome enterprise policies reach both engines
/// (plans/cmux-next/chrome-enterprise-policy-DESIGN.md): Chromium reads
/// Chrome's policy domain itself from its start, and WebKit tabs follow the
/// managed `URLBlocklist` / `URLAllowlist` (Chrome's domain under cmux's
/// browser domain, read by the settings controller) on every load.
@MainActor
enum BrowserManagedPolicyPreference {
    /// Starts following; the caller keeps the returned followers while WebKit follows the policy (the app's life).
    static func follow(_ settings: SettingsController, webKit: WebKitEngine, chromium: ChromiumEngineSlot,
                       on mainWork: MainWorkScheduler) -> [AnyObject] {
        chromium.whenBuilt { cef in  // asked once, at Chromium's start: following builds no engine
            cef.chromePolicyID = {
                ChromePolicyDocument.nativePolicyDomain(cmuxBrowser: CFChromePolicyReader(domain: ChromePolicyDocument.cmuxDomain).read())
            }
        }
        // `automation`: another process (the device management profile) changes the policy. The current one
        // applies now, before any page loads: the launch read's forced values until the first load.
        let policy = ServiceObservation(.automation, owner: "BrowserManagedPolicyPreference", on: mainWork) {
            ManagedURLFilters(settings.managedPolicyInEffect)
        } apply: { [weak webKit] lists in
            let filter = BrowserURLFilter(blocklist: lists.blocklist, allowlist: lists.allowlist)
            if let webKit, webKit.urlFilter != filter { webKit.urlFilter = filter }
        }
        return [policy]
    }
}
