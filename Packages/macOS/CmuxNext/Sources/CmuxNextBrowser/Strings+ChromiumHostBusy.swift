import Foundation

// The Chromium Host's busy banner (ChromiumHostBusyBanner).
extension Strings {
    static var chromiumHostBusy: String {
        String(localized: "browser.chromiumHost.busy.title", defaultValue: "Chromium is busy", bundle: .module)
    }
    static var chromiumHostBusyWait: String {
        String(localized: "browser.chromiumHost.busy.wait", defaultValue: "Wait", bundle: .module)
    }
    static var chromiumHostBusyReload: String {
        String(localized: "browser.chromiumHost.busy.reload", defaultValue: "Reload Chromium", bundle: .module)
    }
}
