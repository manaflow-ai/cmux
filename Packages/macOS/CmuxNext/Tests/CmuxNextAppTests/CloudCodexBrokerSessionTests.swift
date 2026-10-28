import Foundation
import Darwin
import Testing
@testable import CmuxNextCloud

/// No `.timeLimit`: every wait here is on a reply or an exit, and none checks
/// a deadline. Each test starts a python3 holder; in the full parallel package run,
/// where tests take 100-500 s of wall clock, the 1 minute limit expired on
/// cancellationOnlySettlesItsCaller before its replies arrived. A holder that
/// never answers is a hang that scripts/cmux-next/swift-test-with-hang-sampler.sh
/// names and samples.
@Suite("Cloud Codex broker private pipe")
struct CloudCodexBrokerSessionTests {
    private func withSession(_ body: (CodexBrokerSession, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("holder.py")
        try Self.holder.write(to: script, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path
        environment["SSL_CERT_FILE"] = root.appendingPathComponent("ca.pem").path
        environment["SSL_CERT_DIR"] = root.appendingPathComponent("certs").path
        environment["UNRELATED_SECRET"] = "must-not-inherit"
        let session = try CodexBrokerSession(executable: URL(fileURLWithPath: "/usr/bin/env"),
            executablePrefix: ["python3", script.path], codexExecutable: URL(fileURLWithPath: "/unused"),
            home: root, inheritedEnvironment: environment)
        do { try await body(session, root) }
        catch { await session.shutdown(); throw error }
        await session.shutdown()
    }

    @Test(arguments: ["timeout", "account"])
    func typedErrors(_ method: String) async throws {
        try await withSession { session, _ in
            do {
                _ = try await session.request(method: method)
                Issue.record("expected typed error")
            } catch CodexBrokerSession.Error.timedOut { #expect(method == "timeout") }
            catch CodexBrokerSession.Error.accountChanged { #expect(method == "account") }
        }
    }

    @Test func cancellationOnlySettlesItsCaller() async throws {
        try await withSession { session, _ in
            let first = Task { try await session.request(method: "cancel-me") }
            let survivor = Task { try await session.request(method: "survivor") }
            // The fixture replies only after both requests are pending.
            _ = try await session.request(method: "barrier")
            first.cancel()
            do { _ = try await first.value; Issue.record("cancelled request succeeded") }
            catch is CancellationError {}
            _ = try await session.request(method: "release")
            #expect(try await survivor.value.chatgptAccountID == "survived")
        }
    }

    @Test func shutdownWaitsForChildExit() async throws {
        try await withSession { session, root in
            _ = try await session.request(method: "ready")
            await session.shutdown()
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("exited").path))
        }
    }

    @Test func shutdownEscalatesOnlyOwnedHolderThatIgnoresTERM() async throws {
        try await withSession { session, _ in
            let reply = try await session.request(method: "ignore-term")
            let pid = try #require(reply.chatgptAccountID.flatMap(Int32.init))
            // The holder ignores SIGTERM, so both shutdowns returning with the
            // holder gone proves the SIGKILL escalation; without it they never
            // return, a hang the sampler names. No wall-clock bound: a starved
            // full parallel run took 71 s for the 2 s grace and the exit hop.
            async let first: Void = session.shutdown()
            async let second: Void = session.shutdown()
            _ = await (first, second)
            let killResult = kill(pid, 0)
            let killErrno = errno
            #expect(killResult == -1)
            #expect(killErrno == ESRCH)
        }
    }

    @Test func childKeepsTLSAndTemporaryDirectoryEnvironment() async throws {
        try await withSession { session, root in
            let reply = try await session.request(method: "environment")
            let data = Data(try #require(reply.chatgptAccountID).utf8)
            let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(values["TMPDIR"] == root.path)
            #expect(values["SSL_CERT_FILE"] == root.appendingPathComponent("ca.pem").path)
            #expect(values["SSL_CERT_DIR"] == root.appendingPathComponent("certs").path)
            #expect(values["UNRELATED_SECRET"] == nil)
        }
    }

    private static let holder = #"""
import json, os, signal, sys, time
root = sys.argv[sys.argv.index('--home') + 1]
def terminated(*_):
    # An owned child may still be releasing its credential lock after SIGTERM.
    time.sleep(0.1)
    open(os.path.join(root, 'exited'), 'w').close()
    sys.exit(0)
signal.signal(signal.SIGTERM, terminated)
pending = {}
barrier = None
def reply(id, account='ok', error=None):
    value = {'id': id, 'error': error} if error else {'id': id, 'result': {'chatgptAccountId': account}}
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method, id = request['method'], request['id']
    if method in ('cancel-me', 'survivor'): pending[method] = id
    elif method == 'barrier': barrier = id
    elif method == 'release':
        for key, value in pending.items(): reply(value, 'survived')
        pending.clear()
        reply(id)
    elif method == 'timeout':
        reply(id, error='codex_auth_timeout')
        sys.exit(0)
    elif method == 'account': reply(id, error='codex_auth_account_changed')
    elif method == 'ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        reply(id, str(os.getpid()))
    elif method == 'environment':
        reply(id, json.dumps({k: os.environ[k] for k in ('TMPDIR', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'UNRELATED_SECRET') if k in os.environ}))
    else: reply(id)
    if barrier is not None and len(pending) == 2:
        reply(barrier)
        barrier = None
"""#
}
