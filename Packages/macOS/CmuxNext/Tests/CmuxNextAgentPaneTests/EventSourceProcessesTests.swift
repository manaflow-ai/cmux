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
        }

        var reads: [Read] { state.withLock { $0.reads } }

        func set(_ pid: pid_t, _ process: EventSourceProcess?) { state.withLock { $0.processes[pid] = process } }

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
                    let id = state.withLock { state in
                        state.nextWatch += 1
                        state.watches[pid, default: [:]][state.nextWatch] = exited
                        return state.nextWatch
                    }
                    return { [self] in state.withLock { _ = $0.watches[pid]?.removeValue(forKey: id) } }
                },
                queue: queue)
        }
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
}
