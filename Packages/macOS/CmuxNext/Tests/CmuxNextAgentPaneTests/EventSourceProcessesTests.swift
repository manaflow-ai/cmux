import AppKit
import CmuxNextCompat
import Darwin
import Testing
@testable import CmuxNextAgentPane

/// P-MAIN S5 (2026-10-30): the agent pane's gesture monitor (``AgentPanePersonInput``) and the app-wide
/// ``PersonInputLedger`` (``PersonInputCheck``) called `proc_pidpath` on the main thread for each key
/// and mouse event a process posted (source pid not 0): a system call on the key path. The key path
/// now reads only a table of posting processes; each process is read once, off the main thread, and
/// its exit removes it, so a pid the kernel gives to a new process is read again.
@Suite(.serialized)
@MainActor
struct EventSourceProcessesTests {
    static let screenSharing = "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd"
    static let script = "/usr/bin/python3"

    /// Processes the test makes, replaces and ends; it records each read (pid and whether it ran on the
    /// main thread) and runs each armed exit watch on the table's queue when the test ends the process.
    nonisolated final class FakeProcesses: Sendable {
        nonisolated struct Read: Equatable { var pid: pid_t; var onMain: Bool }
        let queue = DispatchQueue(label: "com.cmuxterm.next.event-source-processes", qos: .userInitiated)
        private let state = Mutex(State())

        private nonisolated struct State {
            var processes: [pid_t: EventSourceProcess] = [:]
            var reads: [Read] = []
            var watches: [pid_t: [Int: @Sendable () -> Void]] = [:]
            var nextWatch = 0
            var refused: Set<pid_t> = []
        }

        var reads: [Read] { state.withLock { $0.reads } }

        func set(_ pid: pid_t, _ process: EventSourceProcess?) { state.withLock { $0.processes[pid] = process } }

        /// The kernel refuses (true) or attaches (false) an exit watch on `pid`.
        func refuseWatch(_ pid: pid_t, _ refused: Bool) {
            state.withLock { state in
                if refused { state.refused.insert(pid) } else { state.refused.remove(pid) }
            }
        }

        /// The process ends: every watch armed on its pid runs, on the table's queue.
        func end(_ pid: pid_t) {
            let fired = state.withLock { state in
                state.processes[pid] = nil
                return Array((state.watches.removeValue(forKey: pid) ?? [:]).values)
            }
            for exited in fired { queue.async(execute: exited) }
        }

        func table() -> EventSourceProcesses {
            EventSourceProcesses(
                resolve: { [self] pid in
                    state.withLock { state in
                        state.reads.append(Read(pid: pid, onMain: pthread_main_np() != 0))
                        return state.processes[pid]
                    }
                },
                watchExit: { [self] pid, _, exited in
                    let id: Int? = state.withLock { state in
                        guard !state.refused.contains(pid) else { return nil }
                        state.nextWatch += 1
                        state.watches[pid, default: [:]][state.nextWatch] = exited
                        return state.nextWatch
                    }
                    guard let id else { return nil }
                    return { [self] in state.withLock { _ = $0.watches[pid]?.removeValue(forKey: id) } }
                },
                queue: queue)
        }
    }

    /// A mouse move posted by `pid`.
    static func move(pid: pid_t) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                           mouseCursorPosition: .zero, mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// A mouse-down posted by `pid` from a source in `state`. No event source: making one (CGEventSource)
    /// can hang inside SkyLight on a headless Mac. The fields are what the checks read.
    static func event(pid: pid_t, state: CGEventSourceStateID = .hidSystemState) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                           mouseCursorPosition: .zero, mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
        cgEvent.setIntegerValueField(.eventSourceStateID, value: Int64(state.rawValue))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// The key path makes no system call: an event from a process not read yet takes the safe default
    /// (not the person's) at once, the process is read once off the main thread, and every later event
    /// from it is judged from the table.
    @Test func theKeyPathReadsOnlyTheTable() async throws {
        let fake = FakeProcesses()
        fake.set(4242, EventSourceProcess(start: 100, path: Self.screenSharing))
        let table = fake.table()
        let event = try Self.event(pid: 4242)
        #expect(!AgentPanePersonInput.isPerson(event, sources: table), "not read yet: the safe default, with no wait")
        await table.settled() // the read posted by the first event has run
        for _ in 0..<100 {
            #expect(AgentPanePersonInput.isPerson(event, sources: table), "Screen Sharing, from the table")
        }
        #expect(fake.reads.count == 1, "one read per process, never one per event")
        #expect(fake.reads.allSatisfy { !$0.onMain }, "never a read on the main thread")
        #expect(table.cached(4242) == EventSourceProcess(start: 100, path: Self.screenSharing))
    }

    /// A pid the kernel gives to a new process (a new start time) is read again: Screen Sharing's pid,
    /// reused by a script after Screen Sharing ends, never keeps Screen Sharing's verdict.
    @Test func aReusedPidIsReadAgain() async throws {
        let fake = FakeProcesses()
        fake.set(4242, EventSourceProcess(start: 100, path: Self.screenSharing))
        let table = fake.table()
        let event = try Self.event(pid: 4242)
        _ = AgentPanePersonInput.isPerson(event, sources: table)
        await table.settled()
        #expect(AgentPanePersonInput.isPerson(event, sources: table))
        fake.end(4242)
        fake.set(4242, EventSourceProcess(start: 200, path: Self.script))
        await table.settled() // the exit has been applied
        #expect(!AgentPanePersonInput.isPerson(event, sources: table), "the script's event, with Screen Sharing's pid")
        await table.settled()
        #expect(!AgentPanePersonInput.isPerson(event, sources: table), "the script, read")
        #expect(table.cached(4242) == EventSourceProcess(start: 200, path: Self.script), "the new process, by its start time")
        #expect(fake.reads.map(\.pid) == [4242, 4242], "read once per process")
        #expect(fake.reads.allSatisfy { !$0.onMain })
    }

    /// A pid with no process (it ended before the read) is not kept: a later event reads it again.
    @Test func aPidWithNoProcessIsNotKept() async throws {
        let fake = FakeProcesses()
        let table = fake.table()
        let event = try Self.event(pid: 4343)
        #expect(!AgentPanePersonInput.isPerson(event, sources: table))
        await table.settled()
        #expect(table.cached(4343) == nil)
        fake.set(4343, EventSourceProcess(start: 300, path: Self.screenSharing))
        #expect(!AgentPanePersonInput.isPerson(event, sources: table), "read again, off the main thread")
        await table.settled()
        #expect(AgentPanePersonInput.isPerson(event, sources: table))
        #expect(fake.reads.count == 2 && fake.reads.allSatisfy { !$0.onMain })
    }

    /// The strict check (the join consent sheet) reads the same table: the WindowServer's event counts
    /// once the WindowServer is read, with no read on the main thread.
    @Test func theStrictCheckReadsOnlyTheTable() async throws {
        let fake = FakeProcesses()
        fake.set(77, EventSourceProcess(start: 1, path: PersonInputCheck.windowServer))
        let table = fake.table()
        let check = PersonInputCheck(sources: table)
        let event = try Self.event(pid: 77)
        #expect(!check.isPerson(event), "not read yet: the safe default")
        await table.settled()
        for _ in 0..<10 { #expect(check.isPerson(event)) }
        #expect(!check.isPerson(try Self.event(pid: 77, state: .privateState)), "the state is read from the event")
        #expect(fake.reads.count == 1 && fake.reads.allSatisfy { !$0.onMain })
    }

    /// A remote session moves the mouse before it clicks: the app's ledger queues the read on the move
    /// (no system call, no verdict), so the first click already counts.
    @Test func aMouseMoveFillsTheTableBeforeTheFirstClick() async throws {
        let fake = FakeProcesses()
        fake.set(4242, EventSourceProcess(start: 100, path: Self.screenSharing))
        let table = fake.table()
        let ledger = PersonInputLedger(check: { _ in false }, sources: table)
        ledger.observe(try Self.move(pid: 4242))
        #expect(ledger.last == nil, "a move is no gesture")
        await table.settled()
        #expect(AgentPanePersonInput.isPerson(try Self.event(pid: 4242), sources: table), "the first click counts")
        #expect(fake.reads.count == 1 && fake.reads.allSatisfy { !$0.onMain })
    }

    /// SECURITY: a process whose exit the kernel will not watch is never kept, so no verdict can outlive
    /// it and pass to a process that reuses its pid. Its events take the safe default and each later one
    /// reads it again, off the main thread.
    @Test func aProcessWithNoExitWatchIsNeverKept() async throws {
        let fake = FakeProcesses()
        fake.set(4242, EventSourceProcess(start: 100, path: Self.screenSharing))
        fake.refuseWatch(4242, true)
        let table = fake.table()
        let event = try Self.event(pid: 4242)
        for _ in 0..<3 {
            #expect(!AgentPanePersonInput.isPerson(event, sources: table), "no watch: never the person's")
            await table.settled()
            #expect(table.cached(4242) == nil)
        }
        #expect(fake.reads.isEmpty, "no watch, no read: nothing to keep")
        fake.refuseWatch(4242, false)
        #expect(!AgentPanePersonInput.isPerson(event, sources: table))
        await table.settled()
        #expect(AgentPanePersonInput.isPerson(event, sources: table), "watched: kept")
        #expect(fake.reads.count == 1 && fake.reads.allSatisfy { !$0.onMain })
    }

    /// The kernel's exit watch, as this user, on processes another user owns: launchd (pid 1, root), the
    /// WindowServer and Screen Sharing's daemon when they run. Prints each answer (`exit-watch-proof:`)
    /// for the PR. And on a child of this test: its exit reaches the handler.
    @Test func theKernelExitWatchAttachesAsThisUser() async throws {
        var targets: [(String, pid_t)] = [("launchd", 1)]
        for (name, label) in [("WindowServer", "com.apple.WindowServer"), ("screensharingd", "com.apple.screensharing")] {
            if let pid = await Task.detached(priority: .userInitiated) { Self.launchdPID(label) }.value { targets.append((name, pid)) } else {
                print("exit-watch-proof: \(name) not running (launchctl print system/\(label) names no pid)")
            }
        }
        for (name, pid) in targets {
            let answer = EventSourceProcesses.exitQueue(pid)
            switch answer {
            case let .success(descriptor):
                close(descriptor)
                print("exit-watch-proof: \(name) pid \(pid) as uid \(getuid()): attached")
            case let .failure(error):
                print("exit-watch-proof: \(name) pid \(pid) as uid \(getuid()): refused errno \(error.code.rawValue) (\(error.code))")
            }
            if name == "launchd" { #expect((try? answer.get()) != nil, "launchd: \(answer)") }
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let queue = DispatchQueue(label: "com.cmuxterm.next.event-source-processes", qos: .userInitiated)
        let exited = AsyncStream<Void>.makeStream()
        let cancel = EventSourceProcesses.kernelExit(child.processIdentifier, queue) { exited.continuation.yield() }
        #expect(cancel != nil, "a child of this test")
        child.terminate()
        var iterator = exited.stream.makeAsyncIterator()
        await iterator.next()
    }

    /// The pid launchd names for system service `label`, nil when it is not running.
    nonisolated static func launchdPID(_ label: String) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = pid_t(parts[1]) { return pid }
        }
        return nil
    }
}
