import Darwin
import Foundation
import os

/// Descriptor the fatal-signal handler writes the signal number into.
nonisolated(unsafe) private var fatalSignalDescriptor: Int32 = -1

/// Writes the signal number ("11\n") with one async-signal-safe write(2),
/// then lets the signal end the process with its default action:
/// - a fault (SEGV, BUS, ILL, FPE, TRAP from the CPU, SYS from a bad system
///   call): return, so the faulting instruction runs again under SIG_DFL
///   and macOS writes its crash report (re-raising here made the end a
///   plain signal with no report);
/// - any other signal, or one sent by a process or by raise/abort (SIGTERM,
///   SIGINT, SIGHUP, abort's SIGABRT): re-raise it, or it would be lost.
///
/// On Darwin arm64 `si_code` cannot tell them apart (XNU never reports `SI_USER`, cx-sjv65), so a
/// signal that arrives as a system call returns (raised, or sent to a waiting thread) is re-raised.
/// One sent to a thread running user code still reads as a fault and is lost, as before.
private let fatalSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    var bytes: (UInt8, UInt8, UInt8) = (UInt8(48 + (signal / 10) % 10), UInt8(48 + signal % 10), 10)
    let descriptor = fatalSignalDescriptor
    if descriptor >= 0 {
        // Only the first signal is recorded (abort() may follow a raise).
        fatalSignalDescriptor = -1
        // concurrency-allow: signal handler context (the process is ending), one 3-byte write to a local file.
        _ = withUnsafeBytes(of: &bytes) { Darwin.write(descriptor, $0.baseAddress, 3) }
    }
    _ = Darwin.signal(signal, SIG_DFL)
    let sentBySoftware = info.map { $0.pointee.si_code == SI_USER || $0.pointee.si_code == SI_QUEUE } ?? true
        || arrivedOnASystemCall(context)
    let fault = signal == SIGSEGV || signal == SIGBUS || signal == SIGILL || signal == SIGFPE || signal == SIGTRAP || signal == SIGSYS
    if sentBySoftware || !fault { _ = raise(signal) }
}

/// Whether the thread was returning from `svc #0x80`: syndrome class 0x15 and that word before the pc.
/// Sentry's re-raise arrives on the `sigreturn` to the faulting pc, which may be unmapped, so the
/// word is read with `vm_read_overwrite` and a failed read is a fault. No context re-raises.
nonisolated func arrivedOnASystemCall(_ context: UnsafeMutableRawPointer?) -> Bool {
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

/// Gives the calling thread an alternate signal stack, so a fatal-signal
/// handler installed with `SA_ONSTACK` still runs when that thread has
/// overflowed its own stack (cx-30ko). Returns the mapping it made, or nil
/// when it made none. A usable alternate stack that is already there
/// (Sentry's) is kept.
@discardableResult
nonisolated private func installAlternateSignalStack() -> UnsafeMutableRawPointer? {
    var current = stack_t()
    guard sigaltstack(nil, &current) == 0 else { return nil }
    if current.ss_flags & SS_DISABLE == 0, current.ss_size >= Int(MINSIGSTKSZ) { return nil }
    let page = Int(getpagesize())
    let size = alternateSignalStackSize()
    // One guard page below the stack: a handler that overflows it faults
    // instead of writing over other memory.
    guard let base = mmap(nil, size + page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
          base != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
    _ = mprotect(base, page, PROT_NONE)
    var stack = stack_t(ss_sp: base.advanced(by: page), ss_size: size, ss_flags: 0)
    if sigaltstack(&stack, nil) != 0 {
        _ = munmap(base, size + page)
        return nil
    }
    return base
}

/// `SIGSTKSZ` (128 KiB) in whole pages; mapped lazily, so a thread whose
/// handler never runs costs address space, not memory.
nonisolated private func alternateSignalStackSize() -> Int {
    let page = Int(getpagesize())
    return (Int(SIGSTKSZ) + page - 1) / page * page
}

/// `pthread_introspection_hook_t`: event, thread, address, size.
private typealias ThreadIntrospectionHook = @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int) -> Void

/// The hook that was installed before ours (Instruments, sanitizers).
// crash-allow: written once on the main thread when the hook is installed, read by thread starts after.
nonisolated(unsafe) private var previousThreadHook: ThreadIntrospectionHook?
/// Holds each thread's alternate stack mapping, freed when the thread exits.
// crash-allow: written once on the main thread before the hook is installed, read-only after.
nonisolated(unsafe) private var alternateStackKey = pthread_key_t()

/// Gives every thread that starts from now on (Chromium's, the system's
/// workers, ours) its own alternate signal stack, so a stack overflow on
/// any of them is recorded too (cx-feao0). `PTHREAD_INTROSPECTION_THREAD_START`
/// (2) runs on the new thread before its start routine. Threads that were
/// already running keep none until the system replaces them.
private let threadStartHook: ThreadIntrospectionHook = { event, thread, address, size in
    if event == 2, let base = installAlternateSignalStack() {
        _ = pthread_setspecific(alternateStackKey, base)
    }
    previousThreadHook?(event, thread, address, size)
}

/// Runs on an exiting thread: turns its alternate stack off if it is still
/// ours, then unmaps it. One the thread cannot turn off stays mapped.
private let alternateStackDestructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { base in
    let page = Int(getpagesize())
    var current = stack_t()
    if sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE == 0, current.ss_sp == base.advanced(by: page) {
        var off = stack_t(ss_sp: nil, ss_size: 0, ss_flags: SS_DISABLE)
        guard sigaltstack(&off, nil) == 0 else { return }
    }
    _ = munmap(base, alternateSignalStackSize() + page)
}

/// Installs `threadStartHook` once. Looked up at run time: the hook is in
/// libSystem's `pthread/introspection.h`, which Swift's Darwin module does
/// not import.
private func installAlternateSignalStackOnNewThreads() {
    // RTLD_DEFAULT
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_introspection_hook_install"),
          pthread_key_create(&alternateStackKey, alternateStackDestructor) == 0 else { return }
    typealias Install = @convention(c) (ThreadIntrospectionHook?) -> ThreadIntrospectionHook?
    previousThreadHook = unsafeBitCast(symbol, to: Install.self)(threadStartHook)
}

/// Marks this run as live, so the next launch can tell a crash from a
/// normal quit (`LaunchRecovery`). Per bundle id, so tagged builds never
/// read each other's marker.
///
/// - `run.json`: pid, launch time, whether this run is a restart, whether
///   it lived past the quick-crash window, and whether a requested quit had
///   begun (`markQuitting`).
/// - `run.signal`: empty until a fatal signal handler writes its number.
///
/// A normal quit removes both. A quit that had begun, or a requested-quit
/// signal (`LaunchRecovery.requestedQuitSignals`), counts as a quit that
/// was asked for, even when the process is then killed before it ends.
///
/// `run.json` is written off the main thread (`RunMarkerFile`); the quit
/// path awaits its `quitting` write (`markQuitting`).
@MainActor
final class AppRunMarker {
    private let directory: URL
    private let file: RunMarkerFile
    private var marker: PreviousRun
    /// The ticket of the newest submitted write.
    private var lastTicket: UInt64 = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    private var survivalTask: Task<Void, Never>?
    private static var threadHookInstalled = false

    /// How this launch follows the previous run.
    let recovery: LaunchRecovery

    private var signalFile: URL { directory.appending(path: "run.signal") }
    private var exceptionFile: URL { directory.appending(path: "run.exception") }

    /// The app's marker folder for `bundleID`.
    static func standardDirectory(bundleID: String?) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux-next", directoryHint: .isDirectory)
            .appending(path: CrashReportWriter.safe(bundleID ?? "unknown"), directoryHint: .isDirectory)
    }

    /// Reads the previous run's marker in `directory`, then marks this run
    /// live and installs the fatal signal handlers.
    init(directory root: URL, now: Date = Date()) {
        self.directory = root
        file = RunMarkerFile(url: root.appending(path: "run.json"), signalURL: root.appending(path: "run.signal"))
        let previous = Self.readPrevious(marker: root.appending(path: "run.json"), signal: root.appending(path: "run.signal"),
                                         exception: root.appending(path: "run.exception"))
        recovery = LaunchRecovery.decide(previous: previous)
        marker = PreviousRun(pid: getpid(), launched: now, recovery: LaunchRecovery.watchesForLoop(previous: previous),
                             survived: false, signal: nil)
        start()
    }

    private func start() {
        do {
            // concurrency-allow: once at launch; a stat when the folder exists (every launch after the first).
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("run marker folder failed: \(String(describing: error), privacy: .public)")
            return
        }
        writeMarker()
        // The previous run's exception was read in init; this run records its own.
        unlink(exceptionFile.path)
        UncaughtExceptionRecorder.install(writingTo: exceptionFile)
        // concurrency-allow: once at launch; truncates a file of at most 3 bytes, no fsync.
        let descriptor = open(signalFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        fatalSignalDescriptor = descriptor
        installHandlers()
        let window = LaunchRecovery.quickCrashWindow
        survivalTask = Task { [weak self] in
            // wakeup-allow: one-shot quick-crash window after launch; fires once
            do { try await Task.sleep(for: window) } catch { return }
            self?.markSurvived()
        }
    }

    /// Installs the fatal signal handlers. Call again after CefInitialize:
    /// Chromium resets these signals to their default action at start.
    /// They run on the faulting thread's alternate signal stack, so a stack
    /// overflow is recorded too: the main thread's, and one on every thread
    /// started after the first call.
    func installHandlers() {
        guard fatalSignalDescriptor >= 0 else { return }
        installAlternateSignalStack()
        if !Self.threadHookInstalled {
            Self.threadHookInstalled = true
            installAlternateSignalStackOnNewThreads()
        }
        // SIGTERM, SIGINT and SIGHUP are requested quits: `QuitSignal` turns
        // them into "Quit, keep sessions" once installed; until then this
        // handler records them.
        let fatal = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS]
        let signals = QuitSignal.isInstalled ? fatal : fatal + LaunchRecovery.requestedQuitSignals.sorted()
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = fatalSignalHandler
            action.sa_flags = SA_RESETHAND | SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
        QuitSignal.reclaim()
    }

    private func markSurvived() {
        marker.survived = true
        writeMarker()
    }

    /// A requested quit has begun (`QuitCoordinator`): the next launch is
    /// clean even if this process is killed before the quit finishes, for
    /// example by dev tooling's SIGKILL after its bounded wait while
    /// Chromium shuts down. Returns once `quitting` is on disk, or false
    /// after `timeout` (the quit goes on either way).
    @discardableResult
    func markQuitting(timeout: Duration = .milliseconds(500)) async -> Bool {
        if marker.quitting != true {
            marker.quitting = true
            writeMarker()
        }
        let written = await file.written(lastTicket, timeout: timeout)
        if !written { logger.error("run marker quit write missed its \(timeout, privacy: .public) deadline") }
        return written
    }

    /// Returns once every write asked for so far is on disk (tests), or
    /// false after `timeout`.
    func flush(timeout: Duration = .seconds(5)) async -> Bool {
        await file.written(lastTicket, timeout: timeout)
    }

    /// A normal quit: the next launch is clean.
    func markCleanExit() {
        survivalTask?.cancel()
        let descriptor = fatalSignalDescriptor
        fatalSignalDescriptor = -1
        if descriptor >= 0 { close(descriptor) }
        UncaughtExceptionRecorder.uninstall()
        unlink(exceptionFile.path)
        file.close()
    }

    /// Encodes the marker (about 120 bytes) and hands it to the background
    /// writer.
    private func writeMarker() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do { lastTicket = file.submit(try encoder.encode(marker)) } catch {
            logger.error("run marker encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static func readPrevious(marker: URL, signal: URL, exception: URL? = nil) -> PreviousRun? {
        // concurrency-allow: once at launch before the first window, a file of about 150 bytes in Application Support.
        guard let data = try? Data(contentsOf: marker) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var run = try? decoder.decode(PreviousRun.self, from: data) else { return nil }
        // concurrency-allow: once at launch before the first window, a file of at most 3 bytes.
        if let text = try? String(contentsOf: signal, encoding: .utf8),
           let first = text.split(whereSeparator: \.isNewline).first,
           let number = Int32(first.trimmingCharacters(in: .whitespaces)), number > 0 {
            run.signal = number
        }
        if let exception { run.exception = UncaughtExceptionRecorder.read(exception) }
        return run
    }
}
