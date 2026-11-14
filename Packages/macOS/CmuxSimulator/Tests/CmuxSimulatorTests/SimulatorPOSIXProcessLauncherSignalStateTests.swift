import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

/// A child launched from a Swift concurrency or dispatch worker thread inherits
/// that thread's nearly full signal mask through `exec`, and any disposition the
/// app left at `SIG_IGN`. Such a child never sees SIGTERM and cannot shut down.
@Suite("Simulator POSIX launcher signal state", .serialized)
struct SimulatorPOSIXProcessLauncherSignalStateTests {
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

    @Test("A child launched from a thread with blocked signals starts clean")
    func childStartsWithEmptyMaskAndDefaultDispositions() throws {
        var output: [Int32] = [-1, -1]
        try #require(pipe(&output) == 0)
        defer { for descriptor in output where descriptor >= 0 { Darwin.close(descriptor) } }

        // SIGXFSZ stands in for a signal the app ignores (as it ignores SIGPIPE);
        // no test in this process relies on it.
        let previousDisposition = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, previousDisposition) }
        var everything = sigset_t()
        sigfillset(&everything)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &everything, &previousMask)
        let launched = Result {
            try SimulatorPOSIXProcessLauncher().launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", Self.probeScript],
                environment: [:],
                currentDirectoryURL: nil,
                standardInputFD: nil,
                standardOutputFD: output[1],
                standardErrorFD: nil,
                fileDescriptorsToClose: output
            )
        }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        let processIdentifier = try launched.get()
        Darwin.close(output[1])
        output[1] = -1

        let report = try FileHandle(fileDescriptor: output[0], closeOnDealloc: false)
            .readToEnd()
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}

        #expect(report == "blocked= ignored=\n")
    }
}
