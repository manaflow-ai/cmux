import CmuxNextCompat
import Darwin
import Foundation

/// What the run marker's fatal-signal handler leaves in `run.signal`: the
/// signal number on the first line ("11"), then the startup task that was
/// running when it came, if startup had not completed.
public nonisolated struct FatalSignalRecord: Equatable, Sendable {
    public var signal: Int32?
    public var startupTask: String?

    /// The running startup task's NUL-terminated static name, 0 once startup
    /// completed: a crash key (Chromium's components/crash/core/common/crash_key.h)
    /// the fatal-signal handler writes after the signal. A signal handler reaches
    /// only process globals (plans/cmux-next/arch-ratchet.json, 2026-10-26).
    private static let startupTaskKey = Atomic<Int>(0)

    /// Reads a `run.signal` file's text. An empty or unreadable file holds
    /// no signal: the process ended with no handler running.
    public init(text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let first = lines.first, let number = Int32(first.trimmingCharacters(in: .whitespaces)), number > 0 else { return }
        signal = number
        startupTask = lines.dropFirst().first.map(String.init)
    }

    /// Names the running startup task (one atomic store); nil once startup
    /// completed.
    public static func setStartupTask(_ name: StaticString?) {
        let bits = name.map { $0.hasPointerRepresentation ? Int(bitPattern: $0.utf8Start) : 0 } ?? 0
        Self.startupTaskKey.store(bits, ordering: .releasing)
    }

    /// Touches the key before a signal handler can, so the handler never
    /// runs its lazy initializer (not async-signal-safe).
    public static func prepare() {
        _ = Self.startupTaskKey.load(ordering: .relaxed)
    }

    /// Writes the running startup task's name and a newline to `descriptor`.
    /// Async-signal-safe: an atomic load, `strnlen` and two `write(2)`s.
    public static func writeStartupTask(to descriptor: Int32) {
        guard let task = UnsafePointer<CChar>(bitPattern: Self.startupTaskKey.load(ordering: .acquiring)) else { return }
        var newline: UInt8 = 10
        // concurrency-allow: signal handler context (the process is ending), a static name to the run marker's local file.
        _ = Darwin.write(descriptor, task, strnlen(task, 80))
        // concurrency-allow: signal handler context (the process is ending), one newline to the same file.
        _ = withUnsafeBytes(of: &newline) { Darwin.write(descriptor, $0.baseAddress, 1) }
    }
}

/// Whether the thread was returning from `svc #0x80`: syndrome class 0x15 and that word before the pc.
/// Sentry's re-raise arrives on the `sigreturn` to the faulting pc, which may be unmapped, so the
/// word is read with `vm_read_overwrite` and a failed read is a fault. No context re-raises.
public nonisolated func arrivedOnASystemCall(_ context: UnsafeMutableRawPointer?) -> Bool {
    #if arch(arm64)
    guard let state = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext else { return true }
    guard state.pointee.__es.__esr >> 26 == 0x15 else { return false }
    let pc = UInt(state.pointee.__ss.__pc)
    guard pc >= 4 else { return false }
    var word: UInt32 = 0, read: vm_size_t = 0
    let result = withUnsafeMutablePointer(to: &word) { vm_read_overwrite(mach_task_self_, vm_address_t(pc - 4), 4, vm_address_t(UInt(bitPattern: $0)), &read) }
    return result == KERN_SUCCESS && read == 4 && word == 0xD400_1001
    #else
    return false
    #endif
}
