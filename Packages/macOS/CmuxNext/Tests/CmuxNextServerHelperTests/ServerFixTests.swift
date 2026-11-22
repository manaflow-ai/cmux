import CmuxNextServerHelper
import Foundation
import Testing

struct ServerFixTests {
    static let custom = """
    Battery Power:
     sleep                1
     womp                 0
    AC Power:
     sleep                7
     disksleep            10
     womp                 0
     autorestart          0
    """

    @Test func everyFixRunsOnlyPmsetWithFixedArguments() {
        for fix in ServerFix.allCases {
            #expect(ServerFix.pmset.path == "/usr/bin/pmset")
            #expect(fix.applyArguments.count == 3)
            #expect(["-a", "-c"].contains(fix.applyArguments[0]))
            #expect(fix.applyArguments[1] == fix.setting)
            #expect(fix.applyArguments.allSatisfy { !$0.contains(" ") && !$0.contains(";") })
        }
        #expect(ServerFix.wakeOnNetworkOn.applyArguments == ["-c", "womp", "1"])
    }

    @Test func readsTheACValueOnly() {
        #expect(ServerFix.systemSleepOffOnAC.currentValue(inCustomOutput: Self.custom) == 7)
        #expect(ServerFix.wakeOnNetworkOn.currentValue(inCustomOutput: Self.custom) == 0)
        #expect(ServerFix.diskSleepOffOnAC.currentValue(inCustomOutput: "AC Power:\n disksleep x\n") == nil)
        #expect(ServerFix.autoRestartOn.currentValue(inCustomOutput: "Battery Power:\n autorestart 1\n") == nil)
    }

    private func call(_ body: (@escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { c in body { c.resume(returning: $0) } }
    }

    @Test func revertRestoresTheUsersOwnValue() async {
        let runner = DryRunFixRunner(customOutput: Self.custom)
        let service = ServerHelperService(runner: runner, priors: MemoryFixPriorStore())
        #expect(await call { service.apply(fixID: "pmset.ac.sleep.0", reply: $0) } == nil)
        #expect(runner.recorded.map(\.1) == [["-g", "custom"], ["-c", "sleep", "0"]])
        #expect(await call { service.apply(fixID: "pmset.ac.sleep.0", reply: $0) } == nil)
        #expect(await call { service.revert(fixID: "pmset.ac.sleep.0", reply: $0) } == nil)
        #expect(runner.recorded.last?.1 == ["-c", "sleep", "7"])
        #expect(await call { service.revert(fixID: "pmset.ac.sleep.0", reply: $0) } == "nothing to revert")
        #expect(await call { service.apply(fixID: "pmset.ac.sleep.0; rm -rf /", reply: $0) } == "unknown fix")
        #expect(runner.recorded.allSatisfy { $0.0.path == "/usr/bin/pmset" })
    }

    @Test func applyThatChangesNothingRecordsNothing() async {
        let runner = DryRunFixRunner(customOutput: "AC Power:\n autorestart 1\n")
        let service = ServerHelperService(runner: runner, priors: MemoryFixPriorStore())
        #expect(await call { service.apply(fixID: "pmset.autorestart.1", reply: $0) } == nil)
        #expect(runner.recorded.map(\.1) == [["-g", "custom"]])
        #expect(await call { service.revert(fixID: "pmset.autorestart.1", reply: $0) } == "nothing to revert")
    }

    @Test func unreadableSettingRefusesTheFix() async {
        let runner = DryRunFixRunner(customOutput: "")
        let service = ServerHelperService(runner: runner, priors: MemoryFixPriorStore())
        #expect(await call { service.apply(fixID: "pmset.ac.womp.1", reply: $0) } == "could not read the current womp setting")
        #expect(runner.recorded.count == 1)
    }

    @Test func aWideStoreDirectoryIsNotTrusted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = FileFixPriorStore(url: directory.appending(path: "x.json"))
        #expect(throws: (any Error).self) { try store.record(.systemSleepOffOnAC, prior: 7) }
        #expect(store.prior(.systemSleepOffOnAC) == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func applyAndRevertDoNotInterleave() async {
        let runner = DryRunFixRunner(customOutput: Self.custom)
        let service = ServerHelperService(runner: runner, priors: MemoryFixPriorStore())
        #expect(await call { service.apply(fixID: "pmset.ac.sleep.0", reply: $0) } == nil)
        async let reverted = call { service.revert(fixID: "pmset.ac.sleep.0", reply: $0) }
        async let applied = call { service.apply(fixID: "pmset.ac.sleep.0", reply: $0) }
        _ = await (reverted, applied)
        // Whatever the order, a later revert restores the user's 7, never a lost value.
        let last = await call { service.revert(fixID: "pmset.ac.sleep.0", reply: $0) }
        #expect(last == nil || last == "nothing to revert")
        #expect(runner.recorded.filter { $0.1 == ["-c", "sleep", "7"] }.count >= 1)
    }

    @Test func fileStoreKeepsTheFirstValue() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-helper-\(UUID().uuidString)/x.json")
        let store = FileFixPriorStore(url: url)
        try store.record(.systemSleepOffOnAC, prior: 7)
        try store.record(.systemSleepOffOnAC, prior: 0)
        #expect(FileFixPriorStore(url: url).prior(.systemSleepOffOnAC) == 7)
        try store.clear(.systemSleepOffOnAC)
        #expect(store.prior(.systemSleepOffOnAC) == nil)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func clientRequirementNamesTheTeamAndTheExactApp() {
        #expect(ServerHelperConstants().clientRequirement(teamID: nil, appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants().clientRequirement(teamID: "", appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants().clientRequirement(teamID: "AB\" or true", appBundleID: "com.cmuxterm.app") == nil)
        #expect(ServerHelperConstants().clientRequirement(teamID: "ABCDE12345", appBundleID: "com.cmuxterm.app\" or true") == nil)
        #expect(ServerHelperConstants().clientRequirement(teamID: "ABCDE12345", appBundleID: "") == nil)
        let req = ServerHelperConstants().clientRequirement(teamID: "ABCDE12345", appBundleID: "com.cmuxterm.app.debug.srv-1")
        #expect(req == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"com.cmuxterm.app.debug.srv-1\"")
    }

    @Test func eachBuildHasItsOwnHelperLabel() {
        #expect(ServerHelperConstants().machServiceName(appBundleID: "com.cmuxterm.app.nightly") == "com.cmuxterm.app.nightly.server-helper")
        #expect(ServerHelperConstants().machServiceName(appBundleID: "com.cmuxterm.app.debug.a") != ServerHelperConstants().machServiceName(appBundleID: "com.cmuxterm.app.debug.b"))
        #expect(ServerHelperConstants().machServiceName(appBundleID: "a b") == nil)
        #expect(ServerHelperConstants().machServiceName(appBundleID: ".com.x") == nil)
        let helper = ServerHelperConstants().helperRequirement(teamID: "ABCDE12345")
        #expect(helper == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"cmux-server-helper\"")
        #expect(ServerHelperConstants().helperRequirement(teamID: nil) == nil)
        #expect(ServerHelperConstants().helperRequirement(teamID: "AB CD") == nil)
    }
}
