import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextCodeRouter
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// cmux issue 59902: `cmux billing status` answered `http_404` on a production Mac. The billing calls
/// (`/api/billing/plan`, `/api/billing/checkout`) went to the Cloud API origin (`cloud-api.cmux.dev`), which has no
/// billing routes; they are cmux.com's, on the web origin. So the plan read, Checkout and Manage Billing all failed.
@MainActor struct BillingClientOriginTests {
    private static func cloud() -> CloudService {
        let api = URL(string: "https://cloud-api.standin.invalid")!
        let web = URL(string: "https://web.standin.invalid")!
        let bundle = "com.cmuxterm.next.dev.billing-origin-\(UUID().uuidString.lowercased())"
        let selection = CloudRuntimeSelection(name: "staging", apiOrigin: api, authWebOrigin: web, vmOrigin: api,
            platformOrigin: api, mobileOrigin: api, deviceHubOrigin: api, shareRoomOrigin: api, shareApiOrigin: api,
            stackOrigin: api, stackProjectId: "staging-project", stackClientKey: "staging-key", bundleId: bundle,
            mutable: true, authNamespace: "staging-2", legacyStorage: false)
        let configuration = CloudConfiguration.from(selection: selection, bundleID: bundle, bundled: [:], process: [:], isDebugBuild: true)
        return CloudService(machines: MachineRegistry(local: DaemonService()), isDebugBuild: true,
                            mainWork: MainWorkScheduler(budget: MainFrameBudget()), work: BackgroundWork(),
                            loginKeychain: LoginKeychain(), configuration: configuration)
    }

    @Test func billingCallsGoToTheWebOriginNotTheCloudAPI() {
        let cloud = Self.cloud()
        #expect(cloud.configuration.apiBaseURL != cloud.configuration.authWebOrigin, "the rig needs two origins")
        let client = CodeRouterClient.billing(cloud.configuration, account: cloud.auth) { AccountLabeler(salt: Data(repeating: 1, count: 32)) }
        #expect(client.baseURL == cloud.configuration.authWebOrigin)
        #expect(client.baseURL != cloud.configuration.apiBaseURL)
    }

    /// cmux.com's own refusal code passes through `cmux billing`; a 404 reads as `http_404`, as the reporter saw.
    @Test func aBillingFailureKeepsTheServersCode() {
        #expect(CodeRouterError.http(status: 403, code: "team_admin_required", message: nil).billingFailure.code == "team_admin_required")
        #expect(CodeRouterError.http(status: 404, code: nil, message: nil).billingFailure.code == "http_404")
        #expect(CodeRouterError.notSignedIn.billingFailure.code == "not_signed_in")
    }
}
