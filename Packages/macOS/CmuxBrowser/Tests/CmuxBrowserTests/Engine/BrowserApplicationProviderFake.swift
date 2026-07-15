@testable import CmuxBrowser

@MainActor
final class BrowserApplicationProviderFake: BrowserApplicationProviding {
    var defaultApplications: [BrowserApplication]
    var chromiumApplications: [BrowserApplication]

    init(defaultApplications: [BrowserApplication], chromiumApplications: [BrowserApplication] = []) {
        self.defaultApplications = defaultApplications
        self.chromiumApplications = chromiumApplications
    }

    func defaultBrowserApplications() -> [BrowserApplication] { defaultApplications }
    func installedChromiumApplications() -> [BrowserApplication] { chromiumApplications }
}
