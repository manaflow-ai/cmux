import CmuxNextAgentPane
import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextDiff
import Foundation
import Testing

/// The diff tab asks its session host for `git.fingerprint`, a read that an older session host
/// does not have. `DiffAgentGit` names the capability `git-fingerprint-v1` for it, so such a host
/// gets no request for it: the read ends in the app as `native.unsupported`, and the page then
/// stops asking.
///
/// The app's real service and the diff tab's real git link run on a stand-in session host behind
/// a bridge (never a real daemon). The git link dials a connection of its own, which is a second
/// stand-in process, so each process appends the name of every frame it gets to one file.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DiffFingerprintCapabilityTests {
    private nonisolated static let script = #"""
    import json, sys
    log, capabilities = sys.argv[1], json.loads(sys.argv[2])
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        with open(log, 'a') as out:
            out.write((frame.get('operation') or frame.get('cmd') or '') + '\n')
        if frame.get('operation') == 'git.fingerprint':
            result = {'fingerprint': 'f' * 64, 'files_read': 0, 'bytes_read': 0}
            print(json.dumps({'id': frame['id'], 'ok': True, 'result': result}), flush=True)
            continue
        data = {}
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'fingerprint-test', 'pid': 4242,
                    'capabilities': capabilities}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    /// The names of the frames the stand-in processes got, in the order they wrote them.
    private static func frames(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Test-harness poll for steps on other tasks; the limit is only a failure deadline.
    private static func eventually(_ done: () -> Bool) async -> Bool {
        for _ in 0..<1000 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    @Test(arguments: [false, true])
    func theDiffTabsGitAsksOnlyASessionHostThatHasTheFingerprintRead(modern: Bool) async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("cn-fingerprint-\(UUID().uuidString.prefix(8)).log")
        defer { try? FileManager.default.removeItem(at: log) }
        // What the git link's own connection requires, and the read's capability only for the modern host.
        let capabilities = DaemonCapability.required + (modern ? [DiffAgentGit.fingerprintCapability] : [])
        let list = String(decoding: try JSONEncoder().encode(capabilities), as: UTF8.self)
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-fingerprint-test-\(UUID().uuidString).sock",
                                      bridge: .fakePython(["-c", Self.script, log.path, list]))
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        let service = DaemonService()
        service.start(makeConnection: { connection })
        defer { service.shutdownConnection() }
        try #require(await Self.eventually { service.startup == .connected }, "the stand-in session host never connected")

        let link = AgentPaneGitLink(daemon: service)
        defer { link.close() }
        let git = DiffAgentGit(link: link)
        var answers: [String] = []
        var failures: [AgentPaneGitFailure] = []
        for _ in 0..<3 {
            do {
                answers.append(try await git.fingerprint("/repo", scope: .uncommitted))
            } catch {
                failures.append(error)
            }
        }

        let frames = Self.frames(log)
        // The control connection and the git link's own connection: the link did reach the host.
        #expect(frames.filter { $0 == "identify" }.count == 2, "the git link did not dial its own connection: \(frames)")
        let asked = frames.filter { $0 == "git.fingerprint" }.count
        if modern {
            #expect(answers == Array(repeating: String(repeating: "f", count: 64), count: 3))
            #expect(failures.isEmpty, "a host with the read refused it: \(failures)")
            #expect(asked == 3, "3 reads sent \(asked) requests: \(frames)")
        } else {
            #expect(answers.isEmpty, "a host without the read gave an answer: \(answers)")
            #expect(failures == Array(repeating: AgentPaneGitFailure.unsupported, count: 3), "\(failures)")
            #expect(asked == 0, "a host without git-fingerprint-v1 got \(asked) git.fingerprint requests: \(frames)")
        }
    }
}
