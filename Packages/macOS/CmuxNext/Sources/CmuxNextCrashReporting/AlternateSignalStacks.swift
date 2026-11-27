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
        if !threadHookInstalled {
            threadHookInstalled = true
            installAlternateSignalStackOnNewThreads()
        }
    }
}

// crash-allow: written once on the main thread, the only caller of installAlternateSignalStacks.
nonisolated(unsafe) private var threadHookInstalled = false

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

