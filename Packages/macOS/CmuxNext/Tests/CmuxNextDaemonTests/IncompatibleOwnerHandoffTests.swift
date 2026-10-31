import Foundation
import Testing
@testable import CmuxNextDaemon

/// An owner an older build started survives an update that changed the protocol (or that requires
/// a capability the owner lacks): the handshake refused it as permanent, so the version handoff
/// never ran and the app showed "Quit and reopen cmux to update it" on every launch. The app's
/// connection now hands such an owner off to the bundled build the way it hands off an owner of
/// another build (`shutdown-daemon` without `end_terminals`), and the refusal shows only when that
/// handoff fails. Each owner here is a scripted stand-in on a bridge that logs what it was sent.
struct IncompatibleOwnerHandoffTests {
    private static let script = #"""
    import json, os, sys
    protocol, capabilities, session, pid, accept, log, upgrade = sys.argv[1:8]
    # `upgrade`: a file whose presence makes this owner the compatible successor.
    if upgrade and os.path.exists(upgrade):
        protocol, pid = '12', str(int(pid) + 1)
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        with open(log, 'a') as out:
            out.write(json.dumps(frame) + '\n')
        ok, result = True, {}
        if command == 'identify':
            result = {'app':'cmux-tui','protocol':int(protocol),'session':session,'pid':int(pid),
                      'generation':'gen-' + pid,'capabilities':json.loads(capabilities)}
        elif command == 'client-hello':
            ok = False
        elif command == 'shutdown-daemon':
            result = {'accepted': accept == 'yes', 'pid': int(pid), 'generation': 'gen-' + pid}
            if accept == 'yes' and upgrade:
                open(upgrade, 'w').close()
        reply = {'id':frame.get('id'),'ok':ok,'data':result}
        if not ok:
            reply.update(error='unknown command', error_code='bad-request')
        print(json.dumps(reply), flush=True)
    """#

    private struct Owner {
        var protocolVersion = 11
        var capabilities: [String] = []
        var session = "cmux-app-test"
        var pid: Int32 = 424_242
        var accepts = true
        var upgrade: URL?
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cnd-incompatible-\(UUID().uuidString.prefix(8))", isDirectory: true)

    private func makeLauncher(bundled: Bool = true, session: String = "cmux-app-test") -> DaemonLauncher {
        DaemonLauncher(configuration: .init(binary: URL(fileURLWithPath: "/usr/bin/false"), session: session,
                                            binaryIsBundled: bundled),
                       environment: { [:] })
    }

    private func makeEndpoint(_ owner: Owner, log: URL) throws -> DaemonEndpoint {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capabilities = String(decoding: try JSONEncoder().encode(owner.capabilities), as: UTF8.self)
        let bridge = DaemonBridge.fakePython([
            "-c", Self.script, String(owner.protocolVersion), capabilities, owner.session, String(owner.pid),
            owner.accepts ? "yes" : "no", log.path, owner.upgrade?.path ?? "",
        ])
        return DaemonEndpoint(socketPath: directory.appendingPathComponent("owner.sock").path, bridge: bridge)
    }

    /// Connects once to `owner` and returns the error the handshake threw (nil: it connected) and
    /// the shutdown requests the owner got.
    private func connect(_ owner: Owner, launcher: DaemonLauncher?, required: [String] = []) async throws
        -> (error: DaemonError?, shutdowns: [[String: Any]]) {
        let log = directory.appendingPathComponent("log-\(UUID().uuidString.prefix(8)).jsonl")
        let base = DaemonConnection.Configuration(requiredCapabilities: required, terminalEnvironment: nil)
        let connection = DaemonConnection(endpoint: try makeEndpoint(owner, log: log),
                                          configuration: launcher?.handingOffIncompatibleOwners(base) ?? base)
        var failure: DaemonError?
        do {
            try await connection.start()
        } catch let error as DaemonError {
            failure = error
        }
        await connection.close()
        return (failure, Self.shutdowns(log))
    }

    private static func shutdowns(_ log: URL) -> [[String: Any]] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.filter { $0["cmd"] as? String == "shutdown-daemon" }
    }

    @Test func anOwnerOfAnOlderProtocolIsHandedOffKeepingItsTerminals() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = makeLauncher()
        let result = try await connect(Owner(), launcher: launcher)
        #expect(result.error == .incompatibleOwnerHandedOff)
        let shutdown = try #require(result.shutdowns.first)
        #expect(result.shutdowns.count == 1)
        #expect(shutdown["pid"] as? Int == 424_242)
        #expect(shutdown["generation"] as? String == "gen-424242")
        #expect(shutdown["end_terminals"] == nil, "a handoff keeps every terminal host alive")
        // The next connect waits this owner out, then `ensure` starts the bundled build.
        #expect(launcher.handoff.exiting == 424_242)
        #expect(!DaemonStartup.shared.isPermanent(.incompatibleOwnerHandedOff))
    }

    @Test func anOwnerMissingARequiredCapabilityIsHandedOff() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await connect(Owner(protocolVersion: 12, capabilities: ["other-v1"]), launcher: makeLauncher(),
                                       required: ["needed-v1"])
        #expect(result.error == .incompatibleOwnerHandedOff)
        #expect(result.shutdowns.count == 1)
    }

    @Test func aSecondIncompatibleOwnerIsRefusedNotHandedOffAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = makeLauncher()
        _ = try await connect(Owner(), launcher: launcher)
        launcher.handoff.cancel(pid: 424_242)
        let again = try await connect(Owner(pid: 424_243), launcher: launcher)
        #expect(again.error == .unsupportedProtocol(11))
        #expect(again.shutdowns.isEmpty)
    }

    @Test func anOwnerOfAnotherSessionIsNeverStopped() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await connect(Owner(session: "cmux-app-other"), launcher: makeLauncher())
        #expect(result.error == .unsupportedProtocol(11))
        #expect(result.shutdowns.isEmpty)
    }

    @Test func anExternalBinaryOrAConnectionWithoutTheHandoffKeepsTheRefusal() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = try await connect(Owner(), launcher: makeLauncher(bundled: false))
        #expect(external.error == .unsupportedProtocol(11))
        #expect(external.shutdowns.isEmpty)
        let plain = try await connect(Owner(), launcher: nil)
        #expect(plain.error == .unsupportedProtocol(11))
        #expect(plain.shutdowns.isEmpty)
    }

    @Test func aRefusedHandoffShowsTheRefusal() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = makeLauncher()
        let result = try await connect(Owner(accepts: false), launcher: launcher)
        #expect(result.error == .unsupportedProtocol(11))
        #expect(result.shutdowns.count == 1)
        #expect(launcher.handoff.exiting == nil)
    }

    /// The startup loop keeps going after a handoff (before, the refusal ended it for good) and
    /// attaches to the successor.
    @Test func theFirstConnectReachesTheSuccessor() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = makeLauncher()
        let log = directory.appendingPathComponent("startup.jsonl")
        let endpoint = try makeEndpoint(Owner(upgrade: directory.appendingPathComponent("upgraded")), log: log)
        let configuration = launcher.handingOffIncompatibleOwners(.init(requiredCapabilities: [], terminalEnvironment: nil))
        let connected = await DaemonStartup.shared.connect(wake: RetryWake(owner: "IncompatibleOwnerHandoffTests")) {
            DaemonConnection(endpoint: endpoint, configuration: configuration)
        } onFailure: { error in
            #expect(error == .incompatibleOwnerHandedOff)
        }
        let (connection, identity) = try #require(connected)
        #expect(identity.protocolVersion == 12)
        #expect(identity.pid == 424_243)
        #expect(Self.shutdowns(log).count == 1)
        await connection.close()
    }
}
