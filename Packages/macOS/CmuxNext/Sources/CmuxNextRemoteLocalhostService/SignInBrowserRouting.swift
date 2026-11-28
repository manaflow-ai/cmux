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
    package private(set) lazy var callbackProfile = offTheRecord.begin()

    package init(localhost: RemoteLocalhostService?, offTheRecord: OffTheRecordProfiles) {
        self.localhost = localhost
        self.offTheRecord = offTheRecord
    }

    package func configuration(for tab: TabModel?, base: BrowserTabConfiguration,
                               configure: Configure?) async -> BrowserTabConfiguration {
        guard let tab, let configure else { return base }
        let approval = localhost?.isSignInApprovalTab(tab.id) == true
        let localApproval = approval && localhost?.boundMachine(ofTab: tab.id) == nil
        if var routed = await configure(tab, base.initialURL, base) {
            let callback = routed.initialURL.map { localhost?.allowsSignInCallback($0, in: tab.id) == true } ?? false
            if localApproval || (approval && callback) {
                routed.profile = callbackProfile
                routed.restoreState = nil
            }
            if !approval || routed.machineStore == nil || callback { return routed }
        }
        var blank = base
        if localApproval { blank.profile = callbackProfile }
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
