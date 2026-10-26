import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The control socket bound before the server accepts (p08-startup-019): `main()` binds it on a lane,
/// the method groups register after the first frame, then the server adopts the listener.
@Suite(.serialized) struct ControlSocketListenerTests {
    private func makeServer(path: String, mode: ControlAccessMode = .automation) -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        return ControlSocketServer(configuration: .init(path: path, accessMode: mode), router: router)
    }

    private func socketInode(_ path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK ? info.st_ino : nil
    }

    /// Whether `descriptor` has something to read within `milliseconds`.
    private func readable(_ descriptor: Int32, within milliseconds: Int32) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&request, 1, milliseconds) > 0
    }

    @Test func aLiveInstancesSocketIsNeverUnlinkedBeforeOrAfterItServes() throws {
        let path = temporarySocketPath()
        // A live instance that bound in main() and still registers its methods: it accepts nothing yet.
        let early = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let inode = try #require(socketInode(path))
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) {
            _ = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        }
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) { try makeServer(path: path).start() }
        #expect(socketInode(path) == inode, "the second launch left the live socket in place")

        // The same instance once it serves.
        let server = makeServer(path: path)
        try server.start(adopting: early)
        defer { server.stop() }
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) {
            _ = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        }
        #expect(socketInode(path) == inode)
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }

    @Test func aStaleSocketIsReclaimedAndTheFileGetsItsMode() throws {
        let path = temporarySocketPath()
        let stale = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        // A crashed run: the file stays, nothing listens.
        _ = stale.take().map { close($0) }
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        defer { listener.discard() }
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func noRequestIsReadBeforeTheLastGroupRegisters() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let server = makeServer(path: path)
        defer { server.stop() }

        // A client that connects at launch waits in the backlog with its request sent.
        let client = try LineClient(path: path)
        let request: JSONValue = ["id": "early", "method": "test.late", "params": [:]]
        let line = Array((request.compactText + "\n").utf8)
        _ = line.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
        #expect(!readable(client.descriptor, within: 100), "nothing answers before the server accepts")

        // The last method group registers, then the server adopts the listener.
        server.router.register([.async("test.late") { _ in .string("late") }])
        try server.start(adopting: listener)
        let response = try JSONValue.parse(Data(client.readLine().utf8))
        #expect(response["id"] == "early")
        #expect(response["result"] == "late", "the early request reached its method, not method_not_found")
    }

    @Test func anOffModeDiscardsTheListenerAndRemovesItsFile() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        #expect(throws: ControlSocketServer.StartError.disabled) { try makeServer(path: path, mode: .off).start(adopting: listener) }
        #expect(socketInode(path) == nil)
        #expect(listener.take() == nil, "a discarded listener has no descriptor")
    }

    @Test func discardRemovesOnlyTheFileItBound() throws {
        let path = temporarySocketPath()
        let first = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        // Something deleted the file and another instance bound the path since.
        unlink(path)
        let second = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        defer { second.discard() }
        let inode = try #require(socketInode(path))
        first.discard()
        #expect(socketInode(path) == inode, "the other instance's socket stays")
    }

    @Test func theCanonicalStateFolderIsTightenedBeforeTheBind() throws {
        let folder = "/tmp/cncl-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let listener = try ControlSocketServer.bindListener(path: folder + "/s.sock", protectStateDirectory: true)
        defer { listener.discard() }
        var info = stat()
        #expect(lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test func aServerBindsItsOwnSocketForAListenerOfAnotherPath() throws {
        let other = try ControlSocketServer.bindListener(path: temporarySocketPath(), protectStateDirectory: false)
        let path = temporarySocketPath()
        let server = makeServer(path: path)
        try server.start(adopting: other)
        defer { server.stop() }
        #expect(socketInode(other.path) == nil, "the listener at the other path is discarded")
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }
}

@MainActor @Suite(.serialized) struct ControlSocketBindTests {
    @MainActor private final class Seen {
        var names: [String] = []
    }

    @Test func everyWaiterGetsTheOutcomeOnceBeforeOrAfterTheBind() throws {
        let bind = ControlSocketBind()
        let seen = Seen()
        bind.whenBound { _ in seen.names.append("early") }
        #expect(seen.names.isEmpty, "nothing runs before the bind finishes")
        bind.finish(.failure(.addressInUse("/tmp/x.sock")))
        bind.finish(.failure(.disabled))  // a second finish changes nothing
        bind.whenBound { outcome in
            if case .failure(.addressInUse) = outcome { seen.names.append("late") }
        }
        #expect(seen.names == ["early", "late"])
    }

    @Test func aServiceWhoseModeIsOffIsNeverBuilt() {
        #expect(throws: ControlSocketServer.StartError.disabled) {
            _ = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                           configuration: .init(path: temporarySocketPath(), accessMode: .off), identity: testIdentity())
        }
    }

    @Test func aPreparedServiceAcceptsOnlyOnceItServes() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
        defer { service.stop() }
        #expect(!service.server.isRunning)
        try service.serve(adopting: listener)
        #expect(service.server.isRunning)
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }

    @Test func discardClosesTheListenerWhenTheBindFinishes() throws {
        let path = temporarySocketPath()
        let bind = ControlSocketBind()
        bind.discard()  // quit, or a resolved mode of off, before the lane finished
        bind.finish(.success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)))
        var info = stat()
        #expect(lstat(path, &info) != 0, "the socket file is removed")
    }

    /// A serve that waited for the bind and runs after quit discarded it never binds the socket again.
    @Test func aServeThatWaitedForADiscardedBindNeverBinds() throws {
        let path = temporarySocketPath()
        let bind = ControlSocketBind()
        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
        defer { service.stop() }
        let results = ServeResults()
        service.serve(after: bind) { results.all.append($0) }  // Control.serve ran before the bind finished
        bind.discard()  // quit
        bind.finish(.success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)))
        #expect(results.all.count == 1)
        #expect(throws: ControlSocketServer.StartError.discarded(path)) { try results.all.first?.get() }
        #expect(!service.server.isRunning)
        var info = stat()
        #expect(lstat(path, &info) != 0, "no socket file is left behind")
    }

    @Test func aServeAfterTheBindAnswersWithThePath() throws {
        let path = temporarySocketPath()
        let bind = ControlSocketBind()
        let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
        defer { service.stop() }
        bind.finish(.success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)))
        let results = ServeResults()
        service.serve(after: bind) { results.all.append($0) }
        #expect(try results.all.first?.get() == path)
        #expect(try LineClient(path: path).send("ping") == "PONG")
    }

    @MainActor private final class ServeResults {
        var all: [Result<String, any Error>] = []
    }
}

/// The control launch's order (p08-startup-019): nothing is served before the first frame, and a
/// client that connected at launch is answered by a method of the last group.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ControlLaunchTests {
    @MainActor private final class Launched {
        var service: ControlService?
        var served: [String] = []
    }

    @Test func noRequestIsAnsweredBeforeEveryGroupRegisteredAfterTheFirstFrame() throws {
        let s = StartupTestScheduler()
        let path = temporarySocketPath()
        let bind = ControlSocketBind()
        bind.finish(.success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)))
        let launched = Launched()
        defer { launched.service?.stop() }
        ControlLaunch.post(on: s.startup, socket: bind, start: { [launched] in
            let service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                     configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
            launched.service = service
            return service
        }, groups: [
            .init("Control.registerLate") { router in router.register([.async("test.late") { _ in .string("late") }]) },
        ], served: { [launched] result in
            if case .success(let path) = result { launched.served.append(path) }
        })

        // A client connects at launch and sends its request before the app serves.
        let client = try LineClient(path: path)
        let request: JSONValue = ["id": "early", "method": "test.late", "params": [:]]
        let line = Array((request.compactText + "\n").utf8)
        _ = line.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
        for _ in 0..<5 { s.fire() }
        #expect(launched.service == nil, "nothing starts before the first frame")
        #expect(launched.served.isEmpty)

        s.complete()  // the first frame committed
        for _ in 0..<10 { s.fire() }
        #expect(launched.served == [path])
        let response = try JSONValue.parse(Data(client.readLine().utf8))
        #expect(response["id"] == "early")
        #expect(response["result"] == "late", "the early request reached the last group's method")
    }
}
