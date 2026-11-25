import CmuxNextAgentActivity
@testable import CmuxNextComputerUse
import Foundation
import Testing

@MainActor
struct ComputerUseHelperLifecycleTests {
    @Test func repeatedEnableSharesThePendingLaunch() async throws {
        let launcher = PendingHelperLauncher()
        let (helper, directory) = makeHelper(launcher)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = helper.request(enabled: true)
        await launcher.waitForLaunch()
        let second = helper.request(enabled: true)
        launcher.finish(pid: 123)
        await first.value
        await second.value
        #expect(launcher.launches == 1)
        #expect(launcher.terminated.isEmpty)
        #expect(helper.state == .running(123))
    }

    @Test func offThenOnDuringLaunchKeepsOneHelper() async throws {
        let launcher = PendingHelperLauncher()
        let (helper, directory) = makeHelper(launcher)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = helper.request(enabled: true)
        await launcher.waitForLaunch()
        let off = helper.request(enabled: false)
        let on = helper.request(enabled: true)
        launcher.finish(pid: 123)
        await first.value
        await off.value
        await on.value
        #expect(launcher.launches == 1)
        #expect(helper.state == .running(123))
    }

    @Test func quitDuringLaunchStopsTheLateHelperAndPreventsAnotherStart() async throws {
        let launcher = PendingHelperLauncher()
        let (helper, directory) = makeHelper(launcher)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = helper.request(enabled: true)
        await launcher.waitForLaunch()
        helper.applicationWillTerminate()
        launcher.finish(pid: 123)
        await first.value
        await helper.apply(enabled: true)
        #expect(launcher.launches == 1)
        #expect(launcher.terminated == [123])
        #expect(helper.configuration == nil)
        #expect(helper.childEnvironment.isEmpty)
    }

    private func makeHelper(_ launcher: PendingHelperLauncher) -> (ComputerUseHelperDaemon, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cua-\(UUID().uuidString.prefix(8))")
        let helper = ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in true }),
                                            candidates: { [URL(fileURLWithPath: "/missing/helper.app")] },
                                            launcher: launcher, staging: .passing(root: directory),
                                            socketPath: directory.appending(path: "socket/cua.sock").path,
                                            stateDirectory: directory.appending(path: "state"))
        return (helper, directory)
    }
}

@MainActor
private final class PendingHelperLauncher: ComputerUseHelperLaunching {
    var launches = 0
    var terminated: [Int32] = []
    private var pending: CheckedContinuation<Int32?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> Int32? {
        launches += 1
        if launches > 1 { return 456 }
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForLaunch() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(pid: Int32) {
        pending?.resume(returning: pid)
        pending = nil
    }

    func terminate(_ pid: Int32) { terminated.append(pid) }

    func isRunning(_ pid: pid_t) -> Bool { true }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}
