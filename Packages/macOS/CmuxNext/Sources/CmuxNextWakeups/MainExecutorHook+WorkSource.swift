import CoreFoundation

extension MainExecutorHook {
    /// The main run loop's source that runs a ``MainExecutorHook``'s passes, in the common modes, so menu tracking
    /// and modal panels run main-actor jobs too (Chrome's `MessagePumpCFRunLoopBase::work_source_`,
    /// base/message_loop/message_pump_apple.mm).
    struct WorkSource {
        /// Makes `hook`'s source and adds it to the main run loop. The source holds `hook` unretained: the caller
        /// keeps `hook` alive until it invalidates the source.
        static func attach(_ hook: MainExecutorHook) -> CFRunLoopSource {
            var context = CFRunLoopSourceContext()
            // SAFETY: unretained; the caller (MainExecutorHook.install) keeps the hook retained while the source is
            // on the run loop, and invalidates the source before it releases that retain.
            context.info = unsafe Unmanaged.passUnretained(hook).toOpaque()
            context.perform = { info in
                guard let info else { return }
                // SAFETY: `info` is the hook attach(_:) was given, alive while its source is valid (above).
                let hook = unsafe Unmanaged<MainExecutorHook>.fromOpaque(info).takeUnretainedValue()
                // main-proof: the source is only on CFRunLoopGetMain(), whose callouts run on the main thread.
                MainActor.assumeIsolated { hook.runPass() }
            }
            let source: CFRunLoopSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            return source
        }
    }
}
