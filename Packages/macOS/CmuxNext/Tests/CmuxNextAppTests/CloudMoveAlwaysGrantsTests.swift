import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextApp

/// Persistent Move-to-Cloud consent is scoped to the Cloud identity and destination,
/// never inherited from the old folder-only preferences.
@MainActor @Suite
struct CloudMoveAlwaysGrantsTests {
    @Test func grantOnlyCoversTheApprovedAccountTeamOriginAndFolder() throws {
        let owner = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-a", teamID: "team-red", cloudOrigin: "https://cmux.com"))
        let otherTeam = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-a", teamID: "team-blue", cloudOrigin: "https://cmux.com"))
        let otherUser = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-b", teamID: "team-red", cloudOrigin: "https://cmux.com"))
        let otherOrigin = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-a", teamID: "team-red", cloudOrigin: "http://localhost:3777"))
        var grants = CloudMoveAlwaysGrants()
        grants.remember("/work/repo", scope: owner, always: true, defaults: nil)

        #expect(grants.contains("/work/repo", scope: owner, defaults: nil))
        #expect(!grants.contains("/work/repo", scope: otherTeam, defaults: nil))
        #expect(!grants.contains("/work/repo", scope: otherUser, defaults: nil))
        #expect(!grants.contains("/work/repo", scope: otherOrigin, defaults: nil))
        #expect(!grants.contains("/work/another", scope: owner, defaults: nil))
        #expect(!grants.contains("/work/repo", scope: nil, defaults: nil))

        // "Ask first next time" takes back exactly this grant.
        grants.remember("/work/repo", scope: otherTeam, always: true, defaults: nil)
        grants.remember("/work/repo", scope: owner, always: false, defaults: nil)
        #expect(!grants.contains("/work/repo", scope: owner, defaults: nil))
        #expect(grants.contains("/work/repo", scope: otherTeam, defaults: nil))
    }

    @Test func legacyFolderPermissionsRequireFreshConsentAndNewGrantsSurviveRelaunch() throws {
        let suite = "cmux-move-consent-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-a", teamID: "team-red", cloudOrigin: "https://cmux.com"))
        defaults.set(["/work/repo"], forKey: "cmux.cloud.moveAlwaysFolders")

        var grants = CloudMoveAlwaysGrants()
        #expect(!grants.contains("/work/repo", scope: scope, defaults: defaults),
                "An old unscoped Always approval must never become this team's grant")
        grants.remember("/work/repo", scope: scope, always: true, defaults: defaults)
        let relaunched = CloudMoveAlwaysGrants()
        #expect(relaunched.contains("/work/repo", scope: scope, defaults: defaults))
        #expect(!relaunched.contains("/work/repo", scope: nil, defaults: defaults))

        grants.remember("/work/repo", scope: scope, always: false, defaults: defaults)
        #expect(!relaunched.contains("/work/repo", scope: scope, defaults: defaults))
    }

    @Test func unsignedOrDamagedPreferenceNeverAuthorizesAMove() throws {
        #expect(CloudMoveAlwaysGrants.Scope(userID: nil, teamID: "t", cloudOrigin: "https://cmux.com") == nil)
        #expect(CloudMoveAlwaysGrants.Scope(userID: "u", teamID: nil, cloudOrigin: "https://cmux.com") == nil)
        #expect(CloudMoveAlwaysGrants.Scope(userID: "u", teamID: "t", cloudOrigin: "") == nil)
        let suite = "cmux-move-consent-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = try #require(CloudMoveAlwaysGrants.Scope(
            userID: "person-a", teamID: "team-red", cloudOrigin: "https://cmux.com"))
        defaults.set(Data("{corrupt".utf8), forKey: CloudMoveAlwaysGrants.defaultsKey)
        #expect(!CloudMoveAlwaysGrants().contains("/work/repo", scope: scope, defaults: defaults))
    }
}
