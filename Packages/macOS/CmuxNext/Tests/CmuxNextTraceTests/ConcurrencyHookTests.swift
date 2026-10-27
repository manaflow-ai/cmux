import CmuxNextCompat
@testable import CmuxNextTrace
import Testing

/// The Swift global-enqueue hook, phase 1 (p09-observability-123): it installs once and never over another
/// hook, the `task` bit picks the recording or the pass-through hook, `task.post` is an instant with no flow id,
/// and the job always goes to the runtime. Serialized: one case installs into this process's runtime and turns
/// on ``TraceRuntime/shared``'s task bit.
@Suite("Concurrency hook", .serialized)
struct ConcurrencyHookTests {
    /// A word standing in for `swift_task_enqueueGlobal_hook`. Each case keeps it alive past the runtime it
    /// installs for.
    private final class Word {
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        init(_ value: UInt64 = 0) { pointer.initialize(to: value) }
        deinit { pointer.deallocate() }
        var hook: ConcurrencyHook { ConcurrencyHook(word: pointer) }
    }

    private static let taskBit = UInt64(1) << UInt64(ConcurrencyHook.taskCategoryBit)

    @Test("Installing fills an empty word once; a repeat is a no-op")
    func installsOnce() throws {
        let word = Word()
        let runtime = TraceRuntime(role: .app)
        let hook = word.hook
        #expect(!hook.isInstalled)
        #expect(try hook.install(following: runtime))
        #expect(hook.isInstalled)
        #expect(word.pointer.pointee == ConcurrencyHook.passThroughBits)
        #expect(try hook.install(following: runtime) == false)
        #expect(word.pointer.pointee == ConcurrencyHook.passThroughBits)
    }

    @Test("Another hook in the word stays and install throws hookTaken")
    func neverReplacesAnotherHook() {
        let foreign: UInt64 = 0x1000
        let word = Word(foreign)
        let runtime = TraceRuntime(role: .app)
        #expect(throws: ConcurrencyHook.InstallError.hookTaken) { _ = try word.hook.install(following: runtime) }
        runtime.setCategoryMask(Self.taskBit)
        runtime.setCategoryMask(0)
        #expect(word.pointer.pointee == foreign)
        #expect(!word.hook.isInstalled)
    }

    /// Off, the word holds the pass-through hook, so cmux adds nothing to the runtime's own load and call; the
    /// task bit swaps it to the recording hook and back, and never to 0.
    @Test("The task bit picks the recording hook, and clearing it puts the pass-through hook back")
    func taskBitPicksTheHook() throws {
        let word = Word()
        let runtime = TraceRuntime(role: .app)
        runtime.setCategoryMask(Self.taskBit)
        #expect(try word.hook.install(following: runtime))
        #expect(word.hook.isRecording) // installed while the bit was already on

        runtime.setCategoryMask(0)
        #expect(word.pointer.pointee == ConcurrencyHook.passThroughBits)
        runtime.setCategoryMask(Self.taskBit | 1)
        #expect(word.pointer.pointee == ConcurrencyHook.recordingBits)
        runtime.setCategoryMask(1) // another category alone
        #expect(word.pointer.pointee == ConcurrencyHook.passThroughBits)

        let other = TraceRuntime(role: .app)
        other.setCategoryMask(Self.taskBit) // a runtime the word does not follow
        #expect(word.pointer.pointee == ConcurrencyHook.passThroughBits)
    }

    @Test("task.post records only while the task category is on")
    func postIsGated() {
        let runtime = TraceRuntime(role: .app)
        ConcurrencyHook.post(priority: TaskPriority.high.rawValue, job: 0x7000, on: runtime)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        runtime.setCategoryMask(Self.taskBit)
        ConcurrencyHook.post(priority: TaskPriority.high.rawValue, job: 0x7000, on: runtime)
        ConcurrencyHook.post(priority: TaskPriority.utility.rawValue, job: 0x7040, on: runtime)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 2)
    }

    @Test("The hook's word is one thin function pointer; the two hooks differ; arg0 keeps clear of the post site")
    func layout() {
        #expect(MemoryLayout<ConcurrencyHook.Hook?>.size == 8)
        #expect(MemoryLayout<UnownedJob>.size == 8)
        #expect(ConcurrencyHook.passThroughBits != 0)
        #expect(ConcurrencyHook.recordingBits != 0)
        #expect(ConcurrencyHook.passThroughBits != ConcurrencyHook.recordingBits)
        let priorityBits = UInt64(UInt8.max) << ConcurrencyHook.priorityShift
        #expect(priorityBits & (1 << 48 - 1) == 0) // a post site's file id and line (bits 0-47) stay 0
        #expect(priorityBits >> 56 == 0)
    }

    /// A job address is reused (a freed task's memory, every run of a default actor), so the record is an
    /// instant: a flow-out would join unrelated jobs into one flow that never ends.
    @Test("A job's task.post: an instant (no flow id), priority in arg0 bits 48-55, the job address in arg1")
    func postFields() {
        let records = Mutex<[TraceRuntime.StubRecord]>([])
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { record in records.withLock { $0.append(record) } })
        runtime.setCategoryMask(Self.taskBit)
        ConcurrencyHook.post(priority: TaskPriority.userInitiated.rawValue, job: 0x1_2345_6780, on: runtime)
        let written = records.withLock { $0 }
        #expect(written.count == 1)
        #expect(written.first?.name == ConcurrencyHook.taskPostName)
        #expect(written.first?.categoryBit == ConcurrencyHook.taskCategoryBit)
        #expect(written.first?.phase == .instant)
        #expect(written.first?.arg0 == UInt64(TaskPriority.userInitiated.rawValue) << 48)
        #expect(written.first?.arg1 == 0x1_2345_6780)
    }

    /// End to end on this process's runtime: jobs still run through both hooks, and with the task bit on,
    /// cooperative-pool jobs write task.post records on the shared runtime.
    @Test("Installed in the runtime, pool jobs run and write task.post", .timeLimit(.minutes(1)))
    func installedInRuntime() async throws {
        let hook = try ConcurrencyHook()
        try hook.install()
        #expect(hook.isInstalled)
        let shared = TraceRuntime.shared
        let mask = shared.requestedCategoryMask
        defer { shared.setCategoryMask(mask) }

        shared.setCategoryMask(mask & ~Self.taskBit)
        #expect(!hook.isRecording)
        #expect(await Task.detached(priority: .utility) { 21 }.value == 21) // off: the job still runs

        shared.setCategoryMask(mask | Self.taskBit)
        #expect(hook.isRecording)
        let before = shared.stubRecordCount.load(ordering: .relaxed)
        let sums = await withTaskGroup(of: Int.self) { group in
            for value in 0..<8 { group.addTask(priority: .medium) { value } }
            return await group.reduce(0, +)
        }
        #expect(sums == 28)
        #expect(shared.stubRecordCount.load(ordering: .relaxed) >= before + 8)
    }
}
