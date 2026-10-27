import CmuxNextCloud
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// This Mac's install id as a launch read (p08-startup-076): `main` reads or makes `device-id` on a lane, and the
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

    @Test func aReadOfOtherPathsIsNotTaken() async {
        let paths = Self.paths()
        let source = CloudDeviceIDSource(paths: paths) { .success("mac-other") }
        #expect(source.result(for: Self.paths()) == nil)
        #expect(source.result(for: paths) == .success("mac-other"))
    }
}
