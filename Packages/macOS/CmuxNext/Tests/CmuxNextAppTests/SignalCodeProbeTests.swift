import Darwin
import Foundation
import Testing

/// Temporary probe (cx-sjv65): what si_code and ESR exception class Darwin
/// delivers for each way a fault signal can arrive. Not for landing.
nonisolated(unsafe) private var probeDescriptor: Int32 = -1

private let probeHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    let code = info?.pointee.si_code ?? -999
    var esr: UInt32 = 0
    var pc: UInt64 = 0
    #if arch(arm64)
    if let mc = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext {
        esr = mc.pointee.__es.__esr
        pc = mc.pointee.__ss.__pc
    }
    #endif
    let line = "PROBE signal=\(signal) si_code=\(code) esr=0x\(String(esr, radix: 16)) ec=0x\(String(esr >> 26, radix: 16)) pc=0x\(String(pc, radix: 16))\n"
    _ = line.withCString { Darwin.write(probeDescriptor, $0, strlen($0)) }
    _exit(0)
}

enum SignalProbe {
    static func file(_ name: String, parent: pid_t) -> String {
        FileManager.default.temporaryDirectory.appending(path: "cmux-sigprobe-\(parent)-\(name)").path
    }

    static func arm(_ name: String) {
        probeDescriptor = open(file(name, parent: getppid()), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        var stack = stack_t(ss_sp: malloc(1 << 16), ss_size: 1 << 16, ss_flags: 0)
        sigaltstack(&stack, nil)
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = probeHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    static func report(_ name: String) {
        let path = file(name, parent: getpid())
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "PROBE none"
        print("SIGPROBE \(name): \(text)")
        Issue.record("SIGPROBE \(name): \(text)")
        unlink(path)
    }

    @inline(never) static func badAccess() { UnsafeMutablePointer<Int>(bitPattern: 16)?.pointee = 1 }
}

struct SignalCodeProbeTests {
    @Test func brk() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("brk"); fatalError("probe") }
        SignalProbe.report("brk")
    }
    @Test func raiseTrap() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("raiseTrap"); raise(SIGTRAP); _exit(3) }
        SignalProbe.report("raiseTrap")
    }
    @Test func raiseSegv() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("raiseSegv"); raise(SIGSEGV); _exit(3) }
        SignalProbe.report("raiseSegv")
    }
    @Test func pthreadKillBus() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("pthreadKillBus"); pthread_kill(pthread_self(), SIGBUS); _exit(3) }
        SignalProbe.report("pthreadKillBus")
    }
    @Test func killSelfSegv() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("killSelfSegv"); kill(getpid(), SIGSEGV); _exit(3) }
        SignalProbe.report("killSelfSegv")
    }
    @Test func realSegv() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("realSegv"); SignalProbe.badAccess(); _exit(3) }
        SignalProbe.report("realSegv")
    }
    @Test func abortCall() async {
        await #expect(processExitsWith: .success) { SignalProbe.arm("abort"); abort() }
        SignalProbe.report("abort")
    }
    @Test func killFromOtherThreadWhileSpinning() async {
        await #expect(processExitsWith: .success) {
            SignalProbe.arm("spin")
            let target = pthread_self()
            var thread: pthread_t?
            var t = target
            pthread_create(&thread, nil, { arg in
                usleep(200_000)
                pthread_kill(arg.assumingMemoryBound(to: pthread_t.self).pointee, SIGSEGV)
                return nil
            }, &t)
            var x: UInt64 = 1
            while true { x = x &* 6364136223846793005 &+ 1; if x == 0 { break } }
            _exit(3)
        }
        SignalProbe.report("spin")
    }
}
