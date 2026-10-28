import Darwin
import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// The thread-start hook's state is one immutable value made once by Swift's global
/// initialization (no unchecked globals). A thread started after the install, and one started while a second
/// install runs, gets its own alternate signal stack, so a stack overflow there still reaches the handler.
@Suite(.serialized) struct AlternateSignalStackTests {
    /// The calling thread's alternate signal stack size; 0 when it has none.
    private static func alternateStackSize() -> Int {
        var current = stack_t()
        guard sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE == 0 else { return 0 }
        return current.ss_size
    }

    /// Runs `body` on a new pthread (Foundation `Thread`) and returns its result.
    private static func onNewThread(_ body: @escaping @Sendable () -> Int) async -> Int {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.start()
        }
    }

    @Test func threadsStartedAfterTheInstallGetAnAlternateStack() async {
        CrashReporter.installAlternateSignalStacks()
        #expect(Self.alternateStackSize() >= Int(MINSIGSTKSZ))
        let size = await Self.onNewThread { Self.alternateStackSize() }
        #expect(size >= Int(MINSIGSTKSZ))
    }

    @Test func installingAgainKeepsOneHook() async {
        CrashReporter.installAlternateSignalStacks()
        let racing = Thread { CrashReporter.installAlternateSignalStacks() }
        racing.start()
        CrashReporter.installAlternateSignalStacks()
        let sizes = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 { group.addTask { await Self.onNewThread { Self.alternateStackSize() } } }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(sizes.count == 8)
        #expect(sizes.allSatisfy { $0 >= Int(MINSIGSTKSZ) })
    }
}
