package import CmuxNextBrowser
package import CmuxNextDaemon
package import Foundation

/// Selects the private Chromium context for approval callbacks and checks
/// whether a replacement page can still be installed after it starts.
@MainActor
package final class SignInBrowserRouting {
    package typealias Configure = @MainActor (TabModel, URL?, BrowserTabConfiguration) async -> BrowserTabConfiguration?

    private let localhost: RemoteLocalhostService?
    private let offTheRecord: OffTheRecordProfiles
    private lazy var callbackProfile = offTheRecord.begin()

    package init(localhost: RemoteLocalhostService?, offTheRecord: OffTheRecordProfiles) {
        self.localhost = localhost
        self.offTheRecord = offTheRecord
    }

    package func configuration(for tab: TabModel?, base: BrowserTabConfiguration,
                               configure: Configure?) async -> BrowserTabConfiguration {
        guard let tab, let configure else { return base }
        let approval = localhost?.isSignInApprovalTab(tab.id) == true
        if var routed = await configure(tab, base.initialURL, base) {
            if !approval || routed.machineStore == nil { return routed }
            if let url = routed.initialURL, localhost?.allowsSignInCallback(url, in: tab.id) == true {
                routed.profile = callbackProfile
                routed.restoreState = nil
                return routed
            }
        }
        var blank = base
        blank.initialURL = nil
        blank.restoreState = nil
        blank.navigationGuard = .noLoopback
        return blank
    }

    package func replace(for key: String, url: URL, tabExists: @MainActor () -> Bool,
                         make: @MainActor () async throws -> any BrowserTab,
                         install: @MainActor (any BrowserTab) -> Void) async {
        let callback = localhost?.allowsSignInCallback(url, in: key) == true
        guard let page = try? await make() else { return }
        guard tabExists(), !callback || localhost?.allowsSignInCallback(url, in: key) == true else {
            page.close()
            return
        }
        install(page)
    }

    package func adopt(_ page: any BrowserTab, for key: String) {
        localhost?.adoptPage(page, key: key)
    }
}
