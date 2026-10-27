import CmuxNextTasks
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import QuartzCore
import Testing

/// The Tasks owner's lines reach the main actor as automation work on the app's scheduler
/// (p04-input-082): another process's socket never runs ahead of a person's pending input. Before,
/// each read hopped with `DispatchQueue.main.async`, a FIFO main-queue job beside the person's keys.
@MainActor @Suite(.serialized) struct SocketTasksSourceSchedulingTests {
    @Test func theOwnersLinesWaitForPendingInputAsAutomationWork() throws {
        let rig = try TasksSocketRig()
        defer { rig.close() }
        rig.input.pending = true
        rig.closePeer()
        // The connection's queue read the end of the stream and posted it: held, never delivered.
        rig.spin { rig.work.postedCount(.automation) == 1 }
        #expect(rig.work.postedCount(.automation) == 1, "the owner's lines were not posted as automation work")
        #expect(!rig.sawDisconnect, "the owner's lines ran while a person's input was pending")
        rig.input.pending = false
        rig.spin {
            rig.frame()
            return rig.sawDisconnect
        }
        #expect(rig.sawDisconnect, "the held lines never ran once the input was dispatched")
        #expect(rig.work.postedCount(.automation) == 0)
    }
}

/// A listening Unix socket the source connects to, and a scheduler on a fake link and a manual
/// stall clock, so only the frames the test fires run held work.
@MainActor private final class TasksSocketRig {
    let input: TasksRigInput
    let work: MainWorkScheduler
    private let source: SocketTasksSource
    private let directory: String
    private let listener: Int32
    private var peer: Int32 = -1
    private(set) var sawDisconnect = false
    private var timestamp: CFTimeInterval = 0

    init() throws {
        let directory = "/tmp/cmux-tasks-\(UInt32.random(in: 0 ... .max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/tasks.sock"
        self.directory = directory
        listener = try TasksSocketRig.listen(path: path)
        let input = TasksRigInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input), clock: ManualClock()) { _ -> (any FrameLink)? in
            TasksRigLink()
        }
        self.input = input
        self.work = work
        source = SocketTasksSource(path: path, mainWork: work)
        source.start { [weak self] event in
            if case .connection(.disconnected) = event { self?.sawDisconnect = true }
        }
        // concurrency-allow: test only; the source connected in start(), so its connection waits in the backlog.
        peer = Darwin.accept(listener, nil, nil)
    }

    /// The owner goes away: the source reads the end of its stream.
    func closePeer() {
        if peer >= 0 { Darwin.close(peer) }
        peer = -1
    }

    func frame() {
        timestamp += 1.0 / 60
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func spin(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func close() {
        source.stop()
        closePeer()
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private static func listen(path: String) throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(socket, 1) == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        return socket
    }
}

@MainActor private final class TasksRigInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor private final class TasksRigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
