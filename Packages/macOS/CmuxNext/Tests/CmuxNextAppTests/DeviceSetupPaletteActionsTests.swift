import CmuxNextAccounts
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextNotifications
import Foundation
import Testing

/// The `cmux` verbs a person can now run from the palette (cmuxterm-hq goals/palette-all-actions.md:
/// every CLI action has a palette entry): `billing portal`, `setup notifications`, `remote-host stop`
/// and `browser profile move|proxy set|proxy clear`. The Rust CLI owns each verb; the palette row runs
/// the same request.
@MainActor @Suite struct DeviceSetupPaletteActionsTests {
    @Test func eachVerbHasAPaletteRowThatLeavesTheVerbToItsOwner() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["billing.openPortal", "notifications.allowDesktop", "remote.stopScreenSession",
                             "browserProfile.move", "browserProfile.setProxy", "browserProfile.clearProxy"] {
            let descriptor = registry.descriptor(for: id)
            #expect(descriptor?.isPaletteVisible == true, "\(id)")
            #expect(descriptor?.surfacePlan.cli == .exempt(.ownerVerb), "\(id)")
        }
        let proxy = registry.descriptor(for: "browserProfile.setProxy")
        #expect(proxy?.arguments.map(\.name) == ["scheme", "host", "port"], "the palette asks for each part, the daemon checks them")
        #expect(registry.descriptor(for: "browserProfile.move")?.arguments.map(\.name) == ["index"])
    }

    @Test func manageBillingOpensThePageBillingPortalOpens() {
        let base = URL(string: "https://cmux.com")!
        #expect(base.billingPortal(team: nil)?.absoluteString == "https://cmux.com/dashboard/billing")
        #expect(base.billingPortal(team: "")?.absoluteString == "https://cmux.com/dashboard/billing")
        #expect(base.billingPortal(team: "team_1")?.absoluteString == "https://cmux.com/dashboard/billing?team=team_1")
    }

    @Test func aProxyIsSentAsTheCLISendsIt() throws {
        func sent(_ request: UpdateBrowserProfileRequest) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        let set = try sent(UpdateBrowserProfileRequest(id: "p_1", proxy: .set(.init(scheme: "socks5", host: "127.0.0.1", port: 1080))))
        #expect(set["browser_profile"] as? String == "p_1")
        let proxy = try #require(set["proxy"] as? [String: Any])
        #expect(proxy["scheme"] as? String == "socks5")
        #expect(proxy["host"] as? String == "127.0.0.1")
        #expect(proxy["port"] as? Int == 1080)
        #expect(proxy["bypass"] == nil, "no bypass rules: the key stays out")
        #expect(try sent(UpdateBrowserProfileRequest(id: "p_1", proxy: .clear))["proxy"] is NSNull, "clear sends null")
        #expect(try sent(UpdateBrowserProfileRequest(id: "p_1", name: "Work")).keys.contains("proxy") == false, "a rename keeps the proxy")
    }

    @Test func aDeniedPermissionOpensTheAppsNotificationsPane() {
        let denied = NotificationPermission(authorization: "denied", alert: false, alertStyle: "none", sound: false, badge: false,
                                            bundleID: "com.cmuxterm.next")
        #expect(denied.isDenied)
        #expect(denied.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.cmuxterm.next")
        let asked = NotificationPermission(authorization: "not_determined", alert: false, alertStyle: "none", sound: false, badge: false,
                                           bundleID: nil)
        #expect(!asked.isDenied)
        #expect(asked.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
