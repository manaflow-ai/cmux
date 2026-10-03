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

    @Test func clientRequirementNamesTheTeamAndTheExactApp() {
        #expect(ServerHelperConstants.clientRequirement(teamID: nil, appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants.clientRequirement(teamID: "", appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants.clientRequirement(teamID: "AB\" or true", appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants.clientRequirement(teamID: "ABCDE12345", appBundleID: "com.cmuxterm.app\" or true") == nil)
        #expect(ServerHelperConstants.clientRequirement(teamID: "ABCDE12345", appBundleID: "") == nil)
        let req = ServerHelperConstants.clientRequirement(teamID: "ABCDE12345", appBundleID: "com.cmuxterm.app.debug.srv-1")
        #expect(req == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"com.cmuxterm.app.debug.srv-1\"")
    }

    @Test func eachBuildHasItsOwnHelperLabel() {
        #expect(ServerHelperConstants.machServiceName(appBundleID: "com.cmuxterm.app.nightly") == "com.cmuxterm.app.nightly.server-helper")
        #expect(ServerHelperConstants.machServiceName(appBundleID: "com.cmuxterm.app.debug.a") != ServerHelperConstants.machServiceName(appBundleID: "com.cmuxterm.app.debug.b"))
        #expect(ServerHelperConstants.machServiceName(appBundleID: "a b") == nil)
        #expect(ServerHelperConstants.machServiceName(appBundleID: ".com.x") == nil)
        let helper = ServerHelperConstants.helperRequirement(teamID: "ABCDE12345")
        #expect(helper == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"cmux-server-helper\"")
        #expect(ServerHelperConstants.helperRequirement(teamID: nil) == nil)
        #expect(ServerHelperConstants.helperRequirement(teamID: "AB CD") == nil)
    }
}
