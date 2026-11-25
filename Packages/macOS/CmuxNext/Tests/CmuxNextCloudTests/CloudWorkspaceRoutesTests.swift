import CmuxNextCloud
import Foundation
import Testing

/// cmux#56531: a Cloud chat's Try another approach (fork runs) and its turn checkpoints are cmux-platform's
/// `/v1/workspaces/{workspace}/…` routes. The API Worker answers 404 for them, and the platform answers the
/// value itself, so every Cloud chat's fork said "Couldn't fork this chat". The daemon's `cloud.owner.fork_run`
/// (cmux-cloud-api fork_runs.rs, tests/fork_runs.rs) reads that value; the app must hand it the platform origin.
@Suite
struct CloudWorkspaceRoutesTests {
    /// A selection whose API Worker and platform are different origins, as every real backend's are.
    @Test func workspaceRoutesGoToThePlatformOriginNotTheAPIWorker() throws {
        let configuration = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.walk", bundled: [:], process: [:], isDebugBuild: true)
        var selection = try #require(configuration.runtimeSelection)
        selection.platformOrigin = URL(string: "https://platform.fixture.invalid")!
        selection.apiOrigin = URL(string: "https://api.fixture.invalid")!
        let selected = configuration.selecting(selection)
        #expect(selected.workspaceAPIBaseURL() == URL(string: "https://platform.fixture.invalid"))
        #expect(selected.workspaceAPIBaseURL() != selected.ownerAPIBaseURL())
        #expect(selected.workspaceAPIBaseURL() == selected.relayAPIBaseURL())
    }
}
