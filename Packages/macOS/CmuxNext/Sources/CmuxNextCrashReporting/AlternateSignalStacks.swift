import Darwin

// The alternate signal stacks of the app's fatal-signal handlers (cx-30ko,
// cx-feao0), moved here from CmuxNextApp's AppRunMarker unchanged.

extension CrashReporter {
    /// Gives the calling thread an alternate signal stack, and (once) every
    /// thread that starts from now on its own, so a fatal-signal handler
    /// installed with `SA_ONSTACK` still runs on a thread that overflowed its
    /// stack. Call on the main thread.
    public static func installAlternateSignalStacks() {
        installAlternateSignalStack()
        // The first read installs the thread-start hook; later reads find it.
        _ = threadStartHookState
    }
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

/// What the thread-start hook reads: the key that holds each thread's
/// alternate stack mapping (freed when the thread exits), and the hook that
/// was installed before ours (Instruments, sanitizers).
private struct ThreadStartHookState: Sendable {
    let stackKey: pthread_key_t
    let previous: ThreadIntrospectionHook?
}

/// The installed hook's state; nil when the hook could not be installed.
/// Made by its first read (``CrashReporter/installAlternateSignalStacks()``,
/// main thread) through Swift's one-time global initialization, which also
/// makes a thread-start event that races the install wait for it; immutable
/// after. Chromium's thread-safe function-local statics (`base::NoDestructor`,
/// base/no_destructor.h) do the same job.
private let threadStartHookState: ThreadStartHookState? = installThreadStartHook()

/// Gives every thread that starts from now on (Chromium's, the system's
/// workers, ours) its own alternate signal stack, so a stack overflow on
/// any of them is recorded too (cx-feao0). `PTHREAD_INTROSPECTION_THREAD_START`
/// (2) runs on the new thread before its start routine. Threads that were
/// already running keep none until the system replaces them.
private let threadStartHook: ThreadIntrospectionHook = { event, thread, address, size in
    guard let state = threadStartHookState else { return }
    if event == 2, let base = installAlternateSignalStack() {
        _ = pthread_setspecific(state.stackKey, base)
    }
    state.previous?(event, thread, address, size)
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

/// Installs `threadStartHook`; called once, by `threadStartHookState`'s
/// initializer. Looked up at run time: the hook is in libSystem's
/// `pthread/introspection.h`, which Swift's Darwin module does not import.
/// The key is made before the hook is installed, so a thread-start event
/// waiting on this initializer never waits on libpthread's key lock.
private func installThreadStartHook() -> ThreadStartHookState? {
    // RTLD_DEFAULT
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pthread_introspection_hook_install") else { return nil }
    var stackKey = pthread_key_t()
    guard pthread_key_create(&stackKey, alternateStackDestructor) == 0 else { return nil }
    typealias Install = @convention(c) (ThreadIntrospectionHook?) -> ThreadIntrospectionHook?
    let previous = unsafeBitCast(symbol, to: Install.self)(threadStartHook)
    return ThreadStartHookState(stackKey: stackKey, previous: previous)
}
