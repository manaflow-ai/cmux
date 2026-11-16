import Foundation
import Testing
@testable import CmuxMobileModel

/// Full verify D1 (2026-10-19): Stack refuses team creation from the
/// client, so the phone creates teams through the cmux service.
@Suite struct ServiceTeamCreationTests {
    let creation = ServiceTeamCreation(apiBase: URL(string: "https://api.example")!)

    @Test func theRequestGoesToTheServiceWithTheName() throws {
        let request = creation.request(accessToken: "tok", name: "fv team")
        #expect(request.url?.absoluteString == "https://api.example/v1/teams")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["name": "fv team"])
    }

    @Test func theAnswerIsTheNewTeam() throws {
        let team = try creation.team(from: Data(#"{"team":{"id":"t-1","name":"fv team"}}"#.utf8), status: 200)
        #expect(team.id == "t-1")
        #expect(team.name == "fv team")
    }

    @Test func aRefusalIsAnErrorNeverASilentSuccess() {
        let unavailable = Data(#"{"error":{"code":"team_creation_unavailable","message":"x"}}"#.utf8)
        #expect(throws: ServiceTeamCreation.Failure.unavailable) { try creation.team(from: unavailable, status: 503) }
        #expect(throws: ServiceTeamCreation.Failure.failed) { try creation.team(from: Data("{}".utf8), status: 200) }
        #expect(throws: ServiceTeamCreation.Failure.failed) { try creation.team(from: Data(), status: 502) }
    }
}

/// Full verify D14: VoiceOver's time matches the row's "now".
@Suite struct RelativeStampSpokenTests {
    @Test func underAMinuteAndSlightlyAheadIsNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stamp = RelativeStamp(now: now)
        #expect(stamp.spoken(for: now.addingTimeInterval(10)) == "now")
        #expect(stamp.spoken(for: now.addingTimeInterval(-30)) == "now")
        #expect(stamp.spoken(for: now.addingTimeInterval(-300)) != "now")
    }
}

/// "The create team button on iOS doesn't work" (2026-11-03): the production mobile service
/// answered every production account 503 `team_creation_unavailable`, so a production build
/// must create teams through the cmux team API, as the Mac does.
@Suite struct TeamCreationRouteTests {
    let web = URL(string: "https://cmux.com")!
    let mobile = URL(string: "https://mobile-api.cmux.dev")!
    let devMobile = URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")!

    @Test func aProductionAccountCreatesThroughTheCmuxTeamAPI() {
        #expect(TeamCreationRoute(productionAccount: true, teamAPIBase: web, mobileServiceBase: mobile) == .teamAPI(web))
        #expect(TeamCreationRoute(productionAccount: true, teamAPIBase: web, mobileServiceBase: nil) == .teamAPI(web))
    }

    @Test func aDevelopmentAccountKeepsTheDevMobileService() {
        // A development build's web API is a localhost dev server; the dev service holds the dev key.
        let localhost = URL(string: "http://localhost:3000")!
        #expect(TeamCreationRoute(productionAccount: false, teamAPIBase: localhost, mobileServiceBase: devMobile) == .mobileService(devMobile))
    }

    @Test func withNothingConfiguredItSaysSo() {
        #expect(TeamCreationRoute(productionAccount: false, teamAPIBase: nil, mobileServiceBase: nil) == .unavailable)
        #expect(TeamCreationRoute(productionAccount: true, teamAPIBase: nil, mobileServiceBase: nil) == .unavailable)
    }
}

/// CMUX-38: Settings → Plan sells App Store plans through cmux.com's
/// `/api/billing/apple/*`, which accepts only production Stack sessions, so only
/// a production-account build gets a billing origin (and the Plan row).
@Suite struct BillingOriginTests {
    let web = URL(string: "https://cmux.com")!
    let devMobile = URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")!

    @Test func aProductionAccountBillsThroughCmuxCom() {
        #expect(TeamCreationRoute(productionAccount: true, teamAPIBase: web, mobileServiceBase: nil).billingOrigin == web)
    }

    @Test func developmentAndStagingBuildsGetNoPlans() {
        let localhost = URL(string: "http://localhost:3000")!
        #expect(TeamCreationRoute(productionAccount: false, teamAPIBase: localhost, mobileServiceBase: devMobile).billingOrigin == nil)
        #expect(TeamCreationRoute(productionAccount: false, teamAPIBase: nil, mobileServiceBase: nil).billingOrigin == nil)
    }
}
