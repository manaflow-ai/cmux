import CmuxNextServerHelper
import Foundation
import Testing

struct ServerFixTests {
    @Test func everyFixRunsOnlyPmsetWithFixedArguments() {
        for fix in ServerFix.allCases {
            #expect(ServerFix.pmset.path == "/usr/bin/pmset")
            #expect(fix.applyArguments.count == 3)
            #expect(fix.revertArguments.count == 3)
            #expect(["-a", "-c"].contains(fix.applyArguments[0]))
            #expect(fix.applyArguments[1] == fix.revertArguments[1])
            #expect(fix.applyArguments.allSatisfy { !$0.contains(" ") && !$0.contains(";") })
        }
    }

    @Test func helperRunsTheAllowlistedArgvAndRefusesUnknownIDs() async {
        let runner = DryRunFixRunner()
        let service = ServerHelperService(runner: runner)
        let applied: String? = await withCheckedContinuation { c in service.apply(fixID: "pmset.autorestart.1") { c.resume(returning: $0) } }
        #expect(applied == nil)
        #expect(runner.recorded.map(\.1) == [["-a", "autorestart", "1"]])
        let refused: String? = await withCheckedContinuation { c in service.apply(fixID: "pmset.ac.sleep.0; rm -rf /") { c.resume(returning: $0) } }
        #expect(refused == "unknown fix")
        let reverted: String? = await withCheckedContinuation { c in service.revert(fixID: "pmset.womp.1") { c.resume(returning: $0) } }
        #expect(reverted == nil)
        #expect(runner.recorded.count == 2)
        #expect(runner.recorded.last?.1 == ["-a", "womp", "0"])
    }

    @Test func clientRequirementNeedsATeamAndRefusesOddTeamStrings() {
        #expect(ServerHelperListener.clientRequirement(teamID: nil) == nil)
        #expect(ServerHelperListener.clientRequirement(teamID: "") == nil)
        #expect(ServerHelperListener.clientRequirement(teamID: "AB\" or true") == nil)
        let req = ServerHelperListener.clientRequirement(teamID: "ABCDE12345")
        #expect(req?.contains("certificate leaf[subject.OU] = \"ABCDE12345\"") == true)
        #expect(req?.hasPrefix("anchor apple generic") == true)
    }
}
