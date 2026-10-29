import CmuxNextCloud
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// This Mac's install id as a launch read: `main` reads or makes `device-id` on a lane, and the
/// main thread's ask never touches the disk: `notReadYet` while the read runs, the id once it ended.
@Suite(.timeLimit(.minutes(1))) struct CloudDeviceIDLaunchReadTests {
    static func paths() -> CloudPaths {
        CloudPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-device-id-\(UUID().uuidString)/cloud-next", isDirectory: true))
    }

    @Test func theReadMakesTheIDOnceAndReadsTheSameIDAfter() async throws {
        let paths = Self.paths(), work = BackgroundWork()
        let first = await LaunchRead(on: work) { paths.deviceIDResult() }.finished()
        let id = try first.get()
        #expect(id.hasPrefix("mac-"))
        let again = await LaunchRead(on: work) { paths.deviceIDResult() }.finished()
        #expect(try again.get() == id)
    }

    @Test func aSlowReadIsNotReadYetAndNeverReadOnTheAskingThread() async throws {
        let paths = Self.paths(), work = BackgroundWork()
        let gate = DispatchSemaphore(value: 0)
        let read = LaunchRead(on: work) { () -> Result<String, CloudDeviceIDError> in
            gate.wait()
            return paths.deviceIDResult()
        }
        let source = CloudDeviceIDSource(paths: paths) { read.value }
        #expect(source.result(for: paths) == .failure(.notReadYet))
        #expect(!FileManager.default.fileExists(atPath: paths.root.path), "the ask read or made the file")
        gate.signal()
        let id = try await read.finished().get()
        #expect(source.result(for: paths) == .success(id))
    }

    /// One failure to make `device-id` at launch does not last the session (window records off, new agent tabs
    /// refused until relaunch): the next ask reads it again on a files lane, and an ask after the folder became
    /// writable gets the id.
    @MainActor @Test func aFailedLaunchReadIsReadAgainOnceTheFolderIsWritable() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-device-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // A file where the Cloud state's folder goes: neither the folder nor device-id can be made.
        let blocker = base.appendingPathComponent("state")
        try Data().write(to: blocker)
        let paths = CloudPaths(root: blocker.appendingPathComponent("cloud-next", isDirectory: true))
        let work = BackgroundWork()
        let read = LaunchRead(on: work) { paths.deviceIDResult() }
        Self.spinMainRunLoop { read.value != nil }
        guard case .failure(.unwritable)? = read.value else {
            Issue.record("the launch read made device-id under a file: \(String(describing: read.value))")
            return
        }
        let deviceID = CloudLocalDeviceID(paths: paths, launch: CloudDeviceIDSource(paths: paths) { read.value }, work: work,
                                          mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        #expect((try? deviceID.id()) == nil, "the failed launch read gave an id")
        try FileManager.default.removeItem(at: blocker)
        var id: String?
        Self.spinMainRunLoop {
            id = try? deviceID.id()
            return id != nil
        }
        let made = try #require(id, "the launch read's failure lasted the session")
        #expect(made.hasPrefix("mac-"))
        #expect(try paths.loadOrCreateDeviceID() == made, "the id asked for is not the one written")
    }

    /// Main run loop passes, where a lane read's reply arrives, until `done` or 5 s.
    @MainActor static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
    }

    @Test func aReadOfOtherPathsIsNotTaken() async {
        let paths = Self.paths()
        let source = CloudDeviceIDSource(paths: paths) { .success("mac-other") }
        #expect(source.result(for: Self.paths()) == nil)
        #expect(source.result(for: paths) == .success("mac-other"))
    }
}
