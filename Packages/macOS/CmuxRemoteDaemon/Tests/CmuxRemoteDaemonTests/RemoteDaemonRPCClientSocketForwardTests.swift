import Darwin
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

/// The baked-VM daemon socket forward carries daemon RPC without a credential
/// of its own, so its local end must be reachable only by the current user.
@Suite("RemoteDaemonRPCClient baked VM socket forward")
struct RemoteDaemonRPCClientSocketForwardTests {
    private static let remoteSocketSuffix = ":/run/cmuxd-remote.sock"

    private func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "fake-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            skipDaemonBootstrap: true
        )
    }

    private func strings() -> RemoteDaemonStrings {
        RemoteDaemonStrings(
            missingPersistentPTYCapability: "missing persistent PTY",
            missingRequiredFunctionality: "missing functionality",
            cloudNotificationClearWorkspaceInvalid: "invalid workspace",
            cloudNotificationClearWorkspaceDenied: "workspace denied",
            cloudNotificationClearSurfaceInvalid: "invalid surface"
        )
    }

    /// A fake `ssh` that records its pid and `-L` spec, then listens where the
    /// spec asks (loopback TCP or a Unix path, honoring the stream-local bind
    /// options like OpenSSH) and answers daemon RPC lines.
    private func makeFakeForward() throws -> (executable: String, record: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-daemon-forward-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("record").path
        let script = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use IO::Socket::INET;
        use IO::Socket::UNIX;
        use Socket qw(SOCK_STREAM);

        my ($spec, $mask, $unlink);
        for (my $i = 0; $i < @ARGV; $i++) {
            my $next = $ARGV[$i + 1] // '';
            $spec = $next if $ARGV[$i] eq '-L';
            if ($ARGV[$i] eq '-o' && $next =~ /^StreamLocalBindMask[= ]([0-7]+)$/i) {
                $mask = oct($1) unless defined $mask;
            }
            if ($ARGV[$i] eq '-o' && $next =~ /^StreamLocalBindUnlink[= ](\S+)$/i) {
                $unlink = lc($1) eq 'yes' unless defined $unlink;
            }
        }
        die "missing -L\n" unless defined $spec;

        open(my $record, '>', 'RECORD_PATH.tmp') or die "record: $!\n";
        print $record "$$\n$spec\n";
        close($record);
        rename('RECORD_PATH.tmp', 'RECORD_PATH') or die "record: $!\n";

        my $server;
        if ($spec =~ /^127\.0\.0\.1:(\d+):/) {
            $server = IO::Socket::INET->new(
                LocalAddr => '127.0.0.1', LocalPort => $1, Listen => 1, ReuseAddr => 1
            ) or die "listen: $!\n";
        } elsif ($spec =~ m{^(/[^:]+):/}) {
            my $path = $1;
            unlink($path) if $unlink;
            umask(defined $mask ? $mask : 0177);
            $server = IO::Socket::UNIX->new(
                Local => $path, Type => SOCK_STREAM, Listen => 1
            ) or die "listen: $!\n";
        } else {
            die "unsupported forward $spec\n";
        }

        my $connection = $server->accept() or die "accept: $!\n";
        $connection->autoflush(1);
        while (my $line = <$connection>) {
            my ($id) = $line =~ /"id":(\d+)/;
            $id = 1 unless defined $id;
            if ($line =~ /"method":"hello"/) {
                print $connection qq({"id":$id,"ok":true,"result":{"capabilities":["proxy.stream.push"],"name":"fake","version":"t","remote_path":"/fake"}}\n);
            } else {
                print $connection qq({"id":$id,"ok":true,"result":{}}\n);
            }
        }
        """#.replacingOccurrences(of: "RECORD_PATH", with: record)
        let executable = directory.appendingPathComponent("fake-ssh-forward")
        try Data(script.utf8).write(to: executable, options: .atomic)
        chmod(executable.path, 0o755)
        return (executable.path, record, directory)
    }

    /// The fake's pid and the local (listening) side of its `-L` spec.
    private func recordedForward(at path: String) throws -> (pid: pid_t, listen: String) {
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        try #require(lines.count == 2)
        let pid = try #require(pid_t(lines[0]))
        let spec = lines[1]
        try #require(spec.hasSuffix(Self.remoteSocketSuffix), "unexpected forward spec \(spec)")
        return (pid, String(spec.dropLast(Self.remoteSocketSuffix.count)))
    }

    private func fileStatus(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private func expectPrivateSocketDirectory(for listen: String) throws -> String {
        try #require(listen.hasPrefix("/"), "forward listens on \(listen), not a private Unix socket")
        #expect(listen.utf8.count <= 103)
        let directory = (listen as NSString).deletingLastPathComponent
        let info = try #require(fileStatus(directory))
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_uid == getuid())
        #expect(info.st_mode & 0o077 == 0)
        return directory
    }

    @Test("forwards the VM daemon to a private Unix socket and removes it on stop")
    func forwardUsesPrivateUnixSocket() throws {
        let fake = try makeFakeForward()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: strings(),
            keepaliveInterval: 60,
            keepaliveTimeout: 60
        ) { _ in }
        defer { client.stop() }
        client.transportExecutableOverride = fake.executable

        try client.start()

        let forward = try recordedForward(at: fake.record)
        let directory = try expectPrivateSocketDirectory(for: forward.listen)
        client.stop()
        #expect(fileStatus(directory) == nil)
    }

    @Test("removes the private forward directory when ssh exits")
    func forwardDirectoryRemovedWhenSSHExits() throws {
        let fake = try makeFakeForward()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let terminated = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: strings(),
            keepaliveInterval: 60,
            keepaliveTimeout: 60
        ) { _ in
            terminated.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = fake.executable

        try client.start()

        let forward = try recordedForward(at: fake.record)
        let directory = try expectPrivateSocketDirectory(for: forward.listen)
        kill(forward.pid, SIGTERM)
        try #require(terminated.wait(timeout: .now() + 5.0) == .success)
        #expect(fileStatus(directory) == nil)
    }
}
