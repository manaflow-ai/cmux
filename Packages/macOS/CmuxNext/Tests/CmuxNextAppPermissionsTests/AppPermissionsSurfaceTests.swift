import CmuxNextApps
@testable import CmuxNextAppPermissions
import Foundation
import Testing

@MainActor
@Suite struct AppPermissionsSurfaceTests {
    @Test func styleSettingParsesTheDebugValue() {
        let setting = AppPermissionsStyleSetting()
        #expect(setting.permissionsStyle == .grouped)
        setting.set(rawValue: "matrix")
        #expect(setting.permissionsStyle == .matrix)
        setting.set(rawValue: "nonsense")
        #expect(setting.permissionsStyle == AppPermissionsStyle.defaultStyle)
        #expect(AppPermissionsStyle.settingKey == "apps.permissions.style")
    }

    @Test func settingsRowsShowOnlyHandPicksInCompleteSandbox() async throws {
        let source = AppPermissionsMockSource(now: Date(timeIntervalSince1970: 0))
        let model = AppPermissionsModel(source: source, selectedAppID: AppPermissionsMockSource.verifiedSample.id)
        let id = AppPermissionsMockSource.verifiedSample.id
        await model.apply(.setProfile(.completeSandbox), appID: id)
        var rows = ScopeRows.settings(try #require(model.records[id]), listing: AppPermissionsMockSource.verifiedSample)
        #expect(rows.filter(\.on).isEmpty)
        #expect(rows.first { $0.scope == "net:status.lumen.dev" }?.lock == .profile)
        await model.apply(.setApproval(scope: "workspace:read", approval: .always), appID: id)
        rows = ScopeRows.settings(try #require(model.records[id]), listing: AppPermissionsMockSource.verifiedSample)
        #expect(rows.filter(\.on).map(\.scope) == ["workspace:read"])
    }

    @Test func consentRowsLockRestrictedScopesForTheTier() {
        let rows = ScopeRows.consent(AppPermissionsMockSource.unverifiedSample.installDraft())
        #expect(rows.first { $0.scope == "fs:write" }?.lock == .tier)
        #expect(rows.first { $0.scope == "clipboard:write" }?.lock == .tier)
        #expect(rows.first { $0.scope == "terminal:execute" }?.maxApproval == .perCall)
        #expect(rows.filter(\.on).map(\.scope) == ["workspace:read"])
    }

    @Test func mockAppsUseOnlyTheirTiersScopes() {
        let source = AppPermissionsMockSource()
        #expect(source.listings.count == 7)
        #expect(source.listings.filter { $0.tier == .firstParty }.map(\.id)
                == ["cmux/search", "cmux/inbox", "cmux/notes", "cmux/coderouter", "cmux/usage"])
        for listing in source.listings {
            let record = source.record(for: listing.id)
            let held = record?.grant.activeScopes ?? []
            let forbidden = held.filter { !AppPermissionPolicy.mayHold($0, tier: listing.tier, reviewed: listing.reviewed) }
            #expect(forbidden.isEmpty)
        }
    }

    @Test func revokeAllDisablesTheAppAndEnableKeepsScopesOff() async throws {
        let source = AppPermissionsMockSource()
        let model = AppPermissionsModel(source: source)
        await model.apply(.revokeAll, appID: "cmux/search")
        let revoked = try #require(model.records["cmux/search"])
        #expect(revoked.grant.disabled && revoked.grant.activeScopes.isEmpty && revoked.grant.fileRoots.isEmpty)
        await model.apply(.enable, appID: "cmux/search")
        #expect(model.records["cmux/search"]?.grant.disabled == false)
        let rows = ScopeRows.settings(try #require(model.records["cmux/search"]), listing: AppPermissionsMockSource.firstParty[0])
        #expect(rows.filter(\.on).isEmpty)
    }
}
