import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The control socket bound before the server accepts: the app binds it on a lane at launch,
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
        // A live instance that bound at launch and still registers its methods: it accepts nothing yet.
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
        // A crashed run: the file stays, nothing listens, and the kernel dropped its owner lock.
        _ = stale.take().map { close($0.descriptor); close($0.lock) }
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
        // Something deleted the file and another process (one that takes no owner lock) bound the path since.
        unlink(path)
        let other = try ControlSocketServer.makeBoundDescriptor(path: path, mode: 0o600, bind: { $1.bind($0) })
        defer { close(other.descriptor); unlink(path) }
        let inode = try #require(socketInode(path))
        first.discard()
        #expect(socketInode(path) == inode, "the other process's socket stays")
    }

    /// A full AF_UNIX listen queue refuses a connect on Darwin (`ECONNREFUSED`), which the probe alone
    /// reads as a dead socket: until the server accepts, clients that connected at launch (and closed
    /// connections, which stay queued) can fill it. The owner lock keeps a second launch off the path.
    @Test func aFullListenQueueNeverLetsASecondLaunchTakeThePath() throws {
        let path = temporarySocketPath()
        let live = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false, compatibilityLink: nil,
                                                        mode: 0o600, backlog: 1, bind: { $1.bind($0) })
        defer { live.discard() }
        let inode = try #require(socketInode(path))
        // Each probe's connection stays queued after it closes: the queue fills.
        var queued = 0
        while queued < 64, ControlSocketServer.probe(path) == .accepted { queued += 1 }
        try #require(queued < 64, "the listen queue filled")
        #expect(ControlSocketServer.probe(path) != .accepted, "the probe alone no longer sees a live instance")

        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) {
            _ = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        }
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) { try makeServer(path: path).start() }
        #expect(socketInode(path) == inode, "the live instance keeps its socket")
    }

    /// The lane makes the compatibility link with the bind (its probe never runs on main), the server
    /// that adopts the listener keeps it, and stop removes it.
    @Test func theLaneMakesTheLinkAndTheAdoptingServerKeepsIt() throws {
        let path = temporarySocketPath()
        let link = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false, compatibilityLink: link)
        var info = stat()
        #expect(lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK, "the bind made the link")
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: path, accessMode: .automation, compatibilityLink: link), router: router)
        try server.start(adopting: listener)
        #expect(try LineClient(path: link).send("ping") == "PONG")
        server.stop()
        #expect(lstat(link, &info) != 0, "stop removes the link")
    }

    @Test func discardRemovesTheLinkAndReleasesThePath() throws {
        let path = temporarySocketPath()
        let link = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false, compatibilityLink: link)
        listener.discard()
        var info = stat()
        #expect(lstat(link, &info) != 0)
        #expect(socketInode(path) == nil)
        let next = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false)
        next.discard()
    }

    /// A listener bound with other file permissions than the server's mode gives is never adopted:
    /// the server binds its own socket with its mode.
    @Test func aListenerOfAnotherFileModeIsNotAdopted() throws {
        let path = temporarySocketPath()
        let listener = try ControlSocketServer.bindListener(path: path, protectStateDirectory: false, compatibilityLink: nil,
                                                            mode: 0o644, backlog: SOMAXCONN, bind: { $1.bind($0) })
        let server = makeServer(path: path)
        try server.start(adopting: listener)
        defer { server.stop() }
        #expect(listener.take() == nil, "the listener was discarded")
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(try LineClient(path: path).send("ping") == "PONG")
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

    /// Policy unchanged: an access mode of `off` from the environment, or from cmux.json (with its
    /// managed layers, read at launch; `password` is retired to `off`), makes no socket file at all.
    @Test(arguments: [
        (["CMUX_NEXT_SOCKET_MODE": "off"], "automation"),
        ([:], "off"),
        ([:], "password"),
    ] as [([String: String], String?)])
    func anOffModeBindsNothing(environment: [String: String], configured: String?) {
        let path = temporarySocketPath()
        let s = StartupTestScheduler()
        let bind = ControlSocketBind.begin(launch: LaunchIdentity(bundleID: "com.cmuxterm.app.debug.test", tag: "test", socketPath: path),
                                           environment: environment, configured: configured, work: s.background, mainWork: s.mainWork)
        guard case .failure(.disabled)? = bind.outcome else {
            Issue.record("expected disabled at once, got \(String(describing: bind.outcome))")
            return
        }
        #expect(access(path, F_OK) != 0, "no socket file")
        #expect(access(path + ".lock", F_OK) != 0, "no lock file either")
    }

    /// The bind runs on a lane and comes back to main: a 0600 socket in a 0700 canonical folder.
    @Test func theLaneBindsA0600SocketInA0700Folder() throws {
        let folder = "/tmp/cncb-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/s.sock"
        let s = StartupTestScheduler()
        let bind = ControlSocketBind.begin(path: path, protectStateDirectory: true, compatibilityLink: nil, accessMode: .automation,
                                           work: s.background, mainWork: s.mainWork)
        let end = Date(timeIntervalSinceNow: 5)
        while bind.outcome == nil, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            s.fire()
        }
        let listener = try #require(try bind.outcome?.get())
        defer { listener.discard() }
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o777 == 0o600)
        #expect(lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700)
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

/// The control launch's order: nothing is served before the first frame, and a
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

    /// A launch whose first frame never commits (no window, no GUI session) serves when the launch
    /// says the frame is missed (at its reveal), not at the 10 s failsafe.
    @Test func aLaunchWithNoFirstFrameServesWhenTheFrameIsMissed() throws {
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
        let client = try LineClient(path: path)
        let request: JSONValue = ["id": "early", "method": "test.late", "params": [:]]
        let line = Array((request.compactText + "\n").utf8)
        _ = line.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }

        s.startup.finishRegistration()
        s.startup.firstFrameMissed(.noWindow)  // no complete(): no frame ever commits
        for _ in 0..<10 { s.fire() }
        #expect(s.startup.completion == nil, "served before startup completed: no failsafe")
        #expect(launched.served == [path])
        let response = try JSONValue.parse(Data(client.readLine().utf8))
        #expect(response["result"] == "late")
    }

    @MainActor private final class Ran {
        var names: [String] = []
    }

    /// A launch whose reveal is not its first frame (hidden, no window) releases the control posts at
    /// the reveal (`releaseAtReveal`); the first-frame ref stays for a late frame or the failsafe.
    @Test(arguments: [StartupPhase.Presentation.noWindow, .hidden])
    func aRevealWithoutAFrameReleasesTheControlPosts(presentation: StartupPhase.Presentation) {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase)
        let ran = Ran()
        s.startup.post(.afterFirstFrame, "Control.serve", on: .main) { [ran] in ran.names.append("serve") }
        ControlLaunch.releaseAtReveal(phase: phase, startup: s.startup)
        for _ in 0..<3 { s.fire() }
        #expect(ran.names.isEmpty, "held while launching")
        phase.noteLaunch(presentation)
        for _ in 0..<3 { s.fire() }
        #expect(ran.names == ["serve"])
        #expect(s.startup.heldRefs.contains("Startup.firstFrame"))
    }

    @Test func aRevealByTheFirstFrameWaitsForThatFramesCommit() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase)
        let ran = Ran()
        s.startup.post(.afterFirstFrame, "Control.serve", on: .main) { [ran] in ran.names.append("serve") }
        ControlLaunch.releaseAtReveal(phase: phase, startup: s.startup)
        phase.noteFirstFrame()
        for _ in 0..<3 { s.fire() }
        #expect(ran.names.isEmpty, "the frame's commit releases them, not the reveal")
        s.startup.firstFrameCommitted()
        for _ in 0..<3 { s.fire() }
        #expect(ran.names == ["serve"])
    }

    /// Without the feature: the service starts, every group registers and it binds, in one call.
    @Test func runRegistersEveryGroupThenBinds() throws {
        let path = temporarySocketPath()
        var served: [Result<String, any Error>] = []
        var service: ControlService?
        defer { service?.stop() }
        ControlLaunch.run(start: {
            service = try ControlService.prepare(registry: ActionRegistry(catalog: []), settingsStore: nil,
                                                 configuration: .init(path: path, accessMode: .automation), identity: testIdentity())
            return service
        }, groups: [
            .init("Control.registerLate") { router in router.register([.async("test.late") { _ in .string("late") }]) },
        ], served: { served.append($0) })
        #expect(try served.first?.get() == path)
        #expect(try LineClient(path: path).call("test.late")["result"] == "late")
    }
}
