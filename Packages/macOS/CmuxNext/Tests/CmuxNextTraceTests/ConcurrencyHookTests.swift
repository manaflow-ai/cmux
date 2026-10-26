import CmuxNextCompat
@testable import CmuxNextTrace
import Testing

/// The Swift global-enqueue hook, phase 1 (p09-observability-123): it installs once and never over another
/// hook, writes `task.post` only while the task category is on, and always hands the job to the runtime.
/// Serialized: one case installs into this process's runtime and turns on ``TraceRuntime/shared``'s task bit.
@Suite("Concurrency hook", .serialized)
struct ConcurrencyHookTests {
    /// A zeroed word standing in for `swift_task_enqueueGlobal_hook`.
    private final class Word {
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        init(_ value: UInt64 = 0) { pointer.initialize(to: value) }
        deinit { pointer.deallocate() }
        var hook: ConcurrencyHook { ConcurrencyHook(slot: AtomicPointerSlot(pointer)) }
    }

    @Test("Installing fills an empty word once; a repeat is a no-op")
    func installsOnce() throws {
        let word = Word()
        let hook = word.hook
        #expect(!hook.isInstalled)
        #expect(try hook.install())
        #expect(hook.isInstalled)
        #expect(word.pointer.pointee == ConcurrencyHook.hookBits)
        #expect(try hook.install() == false)
        #expect(word.pointer.pointee == ConcurrencyHook.hookBits)
    }

    @Test("Another hook in the word stays and install throws hookTaken")
    func neverReplacesAnotherHook() {
        let foreign: UInt64 = 0x1000
        let word = Word(foreign)
        #expect(throws: ConcurrencyHook.InstallError.hookTaken) { _ = try word.hook.install() }
        #expect(word.pointer.pointee == foreign)
        #expect(!word.hook.isInstalled)
    }

    @Test("task.post records only while the task category is on")
    func postIsGated() {
        let runtime = TraceRuntime(role: .app)
        ConcurrencyHook.post(priority: TaskPriority.high.rawValue, job: 0x7000, on: runtime)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        runtime.setCategoryMask(1 << UInt64(ConcurrencyHook.taskCategoryBit))
        ConcurrencyHook.post(priority: TaskPriority.high.rawValue, job: 0x7000, on: runtime)
        ConcurrencyHook.post(priority: TaskPriority.utility.rawValue, job: 0x7040, on: runtime)
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 2)
    }

    @Test("The hook's word is one thin function pointer, and the flow bit is above any address")
    func layout() {
        #expect(MemoryLayout<ConcurrencyHook.Hook?>.size == 8)
        #expect(MemoryLayout<UnownedJob>.size == 8)
        #expect(ConcurrencyHook.hookBits != 0)
        #expect(ConcurrencyHook.hookBits == ConcurrencyHook.hookBits)
        #expect(ConcurrencyHook.jobFlowBit == 1 << 63)
        #expect(UInt64(UInt8.max) << ConcurrencyHook.priorityShift < 1 << 32)
    }

    /// End to end on this process's runtime: jobs still run through the original enqueue, and with the task
    /// bit on, cooperative-pool jobs write task.post records on the shared runtime.
    @Test("Installed in the runtime, pool jobs run and write task.post", .timeLimit(.minutes(1)))
    func installedInRuntime() async throws {
        let hook = try ConcurrencyHook()
        try hook.install()
        #expect(hook.isInstalled)
        let shared = TraceRuntime.shared
        let mask = shared.categoryMask
        defer { shared.setCategoryMask(mask) }

        shared.setCategoryMask(mask & ~(1 << UInt64(ConcurrencyHook.taskCategoryBit)))
        #expect(await Task.detached(priority: .utility) { 21 }.value == 21) // off: the job still runs

        shared.setCategoryMask(mask | 1 << UInt64(ConcurrencyHook.taskCategoryBit))
        let before = shared.stubRecordCount.load(ordering: .relaxed)
        let sums = await withTaskGroup(of: Int.self) { group in
            for value in 0..<8 { group.addTask(priority: .medium) { value } }
            return await group.reduce(0, +)
        }
        #expect(sums == 28)
        #expect(shared.stubRecordCount.load(ordering: .relaxed) >= before + 8)
    }
}
