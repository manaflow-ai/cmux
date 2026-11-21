import CmuxFoundation
import Darwin
import Foundation
import Testing

@Suite("POSIX spawn signal policy", .serialized)
struct POSIXSpawnSignalPolicyTests {
    /// Prints the child's blocked and ignored signals as `blocked=<n …> ignored=<n …>`.
    ///
    /// Perl reads its own state before touching it, except SIGFPE, which it
    /// ignores during startup; SIGKILL and SIGSTOP cannot be caught.
    private static let probeScript = #"""
    use POSIX;
    my $mask = POSIX::SigSet->new;
    sigprocmask(SIG_BLOCK, undef, $mask);
    my @blocked = grep { $mask->ismember($_) } 1..31;
    my @ignored;
    for my $n (1..31) {
        next if $n == SIGKILL || $n == SIGSTOP || $n == SIGFPE;
        my $action = POSIX::SigAction->new;
        sigaction($n, undef, $action);
        push @ignored, $n if $action->{HANDLER} eq "IGNORE";
    }
    print "blocked=@blocked ignored=@ignored\n";
    """#

    @Test("A child spawned from a thread with blocked signals starts clean")
    func policyClearsInheritedMaskAndIgnoredSignals() throws {
        let report = try Self.spawnProbe(policy: POSIXSpawnSignalPolicy())
        #expect(report == "blocked= ignored=\n")
    }

    @Test("An inherited disposition is kept while the mask is still cleared")
    func policyCanKeepAnInheritedDisposition() throws {
        let report = try Self.spawnProbe(policy: POSIXSpawnSignalPolicy(inheritingDispositionsOf: [SIGXFSZ]))
        #expect(report == "blocked= ignored=\(SIGXFSZ)\n")
    }

    /// Guards the oracle: without the policy the same spawn leaks both.
    @Test("Without the policy the child inherits the mask and ignored signals")
    func withoutPolicyTheChildInheritsSignalState() throws {
        let report = try Self.spawnProbe(policy: nil)
        #expect(report.hasPrefix("blocked=1 2 3"))
        #expect(report.contains("15"))
        #expect(report.hasSuffix("ignored=\(SIGXFSZ)\n"))
    }

    @Test("Flags set before the policy are kept")
    func policyKeepsExistingFlags() throws {
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        let existing = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try #require(posix_spawnattr_setflags(&attributes, existing) == 0)

        #expect(POSIXSpawnSignalPolicy().apply(to: &attributes) == 0)

        var flags: Int16 = 0
        try #require(posix_spawnattr_getflags(&attributes, &flags) == 0)
        #expect(flags == existing | Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    }

    @Test("Every catchable signal is defaulted")
    func defaultedSignalsCoverEveryCatchableSignal() {
        let signals = POSIXSpawnSignalPolicy().defaultedSignals
        #expect(signals.count == Int(NSIG) - 3)
        #expect(!signals.contains(SIGKILL) && !signals.contains(SIGSTOP))
        #expect(signals.contains(SIGTERM) && signals.contains(SIGINT) && signals.contains(SIGPIPE))
    }

    /// Spawns the probe with every signal blocked on the calling thread and
    /// SIGXFSZ ignored, standing in for a worker thread and the app's ignored
    /// SIGPIPE. No other test in this process relies on SIGXFSZ.
    private static func spawnProbe(policy: POSIXSpawnSignalPolicy?) throws -> String {
        var output: [Int32] = [-1, -1]
        try #require(pipe(&output) == 0)
        defer { for descriptor in output where descriptor >= 0 { Darwin.close(descriptor) } }

        var fileActions: posix_spawn_file_actions_t?
        try #require(posix_spawn_file_actions_init(&fileActions) == 0)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try #require(posix_spawn_file_actions_adddup2(&fileActions, output[1], STDOUT_FILENO) == 0)
        var attributes: posix_spawnattr_t?
        try #require(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        if let policy {
            try #require(policy.apply(to: &attributes) == 0)
        }

        let arguments = ["/usr/bin/perl", "-e", probeScript]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { for value in argv { free(value) } }

        let previousDisposition = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, previousDisposition) }
        var everything = sigset_t()
        sigfillset(&everything)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &everything, &previousMask)
        var processIdentifier: pid_t = 0
        let spawnStatus = argv.withUnsafeMutableBufferPointer { argv in
            posix_spawn(&processIdentifier, "/usr/bin/perl", &fileActions, &attributes, argv.baseAddress, environ)
        }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        try #require(spawnStatus == 0)
        Darwin.close(output[1])
        output[1] = -1

        let report = try FileHandle(fileDescriptor: output[0], closeOnDealloc: false)
            .readToEnd()
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
        return report
    }
}
