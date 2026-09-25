import Foundation
import Testing
@testable import CmuxGit

struct PullRequestDeliveryStatusTests {
    @Test func aggregatesChecksAndDeploymentStatuses() throws {
        let checkRuns = Data(
            """
            {
              "total_count": 3,
              "check_runs": [
                {"name":"unit","status":"completed","conclusion":"success"},
                {"name":"lint","status":"completed","conclusion":"success"},
                {"name":"build","status":"in_progress","conclusion":null}
              ]
            }
            """.utf8
        )
        let statuses = Data(
            """
            {
              "state":"pending",
              "statuses":[
                {"context":"Vercel — Preview","state":"success","target_url":"https://preview.example"}
              ]
            }
            """.utf8
        )

        let result = PullRequestDeliveryStatusParser().parse(
            checkRunsData: checkRuns,
            commitStatusData: statuses
        )

        let checks = try #require(result.checks)
        #expect(checks.state == .pending)
        #expect(checks.passedCount == 2)
        #expect(checks.pendingCount == 1)
        #expect(checks.totalCount == 3)
        let deployment = try #require(result.deployment)
        #expect(deployment.name == "Vercel — Preview")
        #expect(deployment.state == .live)
        #expect(deployment.url?.absoluteString == "https://preview.example")
    }
}
