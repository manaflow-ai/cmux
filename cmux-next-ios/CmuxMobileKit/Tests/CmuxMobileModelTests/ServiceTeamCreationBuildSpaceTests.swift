import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxMobileModel

/// Create Team (`POST /v1/teams` on cmux-mobile-api) carries a dev build's `X-Cmux-Build-Space`.
@Suite struct ServiceTeamCreationBuildSpaceTests {
    @Test func aDevBuildsTeamCreationCarriesItsBuildSpace() throws {
        let base = try #require(URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev"))
        let request = ServiceTeamCreation(apiBase: base, buildSpace: CMUXBuildSpace(devTag: "My_Tag 2"))
            .request(accessToken: "tok", name: "team")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
        let plain = ServiceTeamCreation(apiBase: base, buildSpace: nil).request(accessToken: "tok", name: "team")
        #expect(plain.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }
}
