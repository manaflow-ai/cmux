import AppKit
import Darwin
import Foundation
import ObjectiveC
import Testing

// TEMPORARY (dropped before merge): names what ends the test helper mid-run
// on the macOS 27 report-only lane (exit status 0, no summary line).
@Suite struct AAAExitProbeTests {
    @Test func installTheExitProbe() {
        ExitProbe.install()
    }
}

nonisolated enum ExitProbe {
    nonisolated(unsafe) static var depth = 1

    static func swizzle(_ cls: AnyClass, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return say("no \(name)") }
        let original = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector, OpaquePointer?) -> Void
        let call = unsafeBitCast(original, to: Fn.self)
        let block: @convention(block) (AnyObject, OpaquePointer?) -> Void = { this, arg in
            ExitProbe.say("-[\(NSStringFromClass(cls)) \(name)] at depth \(ExitProbe.depth) in test \(Test.current?.name ?? "none"); stack:\n" + Thread.callStackSymbols.joined(separator: "\n"))
            call(this, selector, arg)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    nonisolated(unsafe) static var installed = false

    static func say(_ text: String) {
        FileHandle.standardError.write(Data("\nexit-probe[\(getpid())]: \(text)\n".utf8))
    }

    static func install() {
        guard !installed else { return }
        installed = true
        atexit {
            ExitProbe.say("exit() called; stack:\n" + Thread.callStackSymbols.joined(separator: "\n"))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ExitProbe.say("NSApplication.willTerminate; stack:\n" + Thread.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { sig, info, _ in
                ExitProbe.say("signal \(sig) from pid \(info?.pointee.si_pid ?? -1); stack:\n" + Thread.callStackSymbols.joined(separator: "\n"))
                signal(sig, SIG_DFL)
                raise(sig)
            }
            action.sa_flags = SA_SIGINFO
            sigaction(sig, &action, nil)
        }
        // What stops the main run loop: the async main's CFRunLoopRun returned and exit(0) followed.
        for name in ["stop:", "stopModal", "stopModalWithCode:", "abortModal", "terminate:"] {
            swizzle(NSApplication.self, name)
        }
        for name in ["cancelTracking", "cancelTrackingWithoutAnimation"] {
            swizzle(NSMenu.self, name)
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                ExitProbe.say("\(note.name.rawValue) at depth \(ExitProbe.depth) in test \(Test.current?.name ?? "none")")
            }
        }
        // The main run loop's nesting: the outermost loop (the async main's CFRunLoopRun) ending is the exit.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.entry, .exit]).rawValue, true, 0) { _, activity in
            if activity == .entry { ExitProbe.depth += 1; return }
            ExitProbe.depth -= 1
            if ExitProbe.depth <= 0 {
                ExitProbe.say("the outermost main run loop ended; stack:\n" + Thread.callStackSymbols.joined(separator: "\n"))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        say("installed on the main thread: \(Thread.isMainThread)")
    }
}
