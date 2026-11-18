@testable import CmuxNextDaemon
import CmuxNextCompat
import Foundation
import Testing

/// Two handshakes in quick succession record the registry id twice; the file must end with the newer one, or the next
/// launch skips this home's own snapshot or draws another session's (cmuxterm-hq#12660).
@Suite struct LaunchRegistryRecorderTests {
    /// The drains the recorder started, run by hand so the order is the test's: newest first, the order that let the
    /// old detached write per handshake leave the older id (each write was its own task, so the first could finish last).
    private final class Drains: Sendable {
        let started = Mutex<[@Sendable () -> Void]>([])
        func runAll() { while let drain = started.withLock({ $0.isEmpty ? nil : $0.removeLast() }) { drain() } }
    }

    private func home() -> (LaunchSnapshotLocation, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-registry-\(UUID().uuidString)")
        return (LaunchSnapshotLocation(defaults: { UserDefaults() }, applicationSupport: { root }), root)
    }

    private func recorded(_ location: LaunchSnapshotLocation) -> String? {
        (try? Data(contentsOf: location.registryFile(session: "cmux-app"))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func twoQuickUpdatesLeaveTheNewerID() {
        let (location, root) = home(); defer { try? FileManager.default.removeItem(at: root) }
        let drains = Drains()
        let recorder = LaunchRegistryRecorder { drain in drains.started.withLock { $0.append(drain) } }
        recorder.record("registry-old", session: "cmux-app", location: location)
        recorder.record("registry-new", session: "cmux-app", location: location)
        // One drain for both: the second id waits behind the first write instead of racing it.
        #expect(drains.started.withLock { $0.count } == 1)
        drains.runAll()
        #expect(recorded(location) == "registry-new")
    }

    @Test func anIDAfterTheDrainEndedStartsAnotherWrite() {
        let (location, root) = home(); defer { try? FileManager.default.removeItem(at: root) }
        let drains = Drains()
        let recorder = LaunchRegistryRecorder { drain in drains.started.withLock { $0.append(drain) } }
        recorder.record("registry-first", session: "cmux-app", location: location)
        drains.runAll()
        #expect(recorded(location) == "registry-first")
        recorder.record("registry-second", session: "cmux-app", location: location)
        #expect(drains.started.withLock { $0.count } == 1)
        drains.runAll()
        #expect(recorded(location) == "registry-second")
    }
}
