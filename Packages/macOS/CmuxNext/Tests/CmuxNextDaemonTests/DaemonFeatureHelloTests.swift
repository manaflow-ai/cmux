import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app's daemon features ride every main-connection `client-hello`, and the
/// daemon's answer, step 2's over step 1's, is what `features.list` reports. The daemon is a script that
/// answers like cmux-tui: step 1 reports the kill switch pending, step 2 (proved) applies it.
struct DaemonFeatureHelloTests {
    private struct CaptureRequest: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-hello-frames"
    }

    private static let script = #"""
    import json, sys
    frames = []
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        result = {}
        if command == 'test-hello-frames':
            result = frames
        else:
            frames.append(frame)
        if command == 'identify':
            result = {'app':'cmux-tui','protocol':12,'generation':'feature-hello-test','capabilities':[]}
        elif command == 'client-hello':
            result = {'connection_id':'test-client'}
            pending = {'name':'flagsFetch','app':False,'daemon':True}
            if 'proof' in frame:
                result.update(verified=True, user_origin_allowed=True,
                    features={'hash':'h2','applied':['flagsFetch'],'pending':[]})
            else:
                result['nonce'] = '00' * 32
                if 'features' in frame:
                    result['features'] = {'hash':'h1','applied':[],'pending':[pending]}
        print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
    """#

    @Test func theHelloCarriesTheFeaturesAndRecordsTheProvedAnswer() async throws {
        let hello = DaemonFeatureHello(hash: "app-hash", values: ["flagsFetch": false, "terminalHolder": true])
        #expect(hello.lastReply == nil)
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script])
        let identity = ClientHelloIdentity(installKey: FrontendInstallKey.generate(), features: hello)
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-feature-hello-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil, clientHello: identity))
        try await connection.start()
        let frames = try #require(try await connection.request(CaptureRequest()).arrayValue)
        let step1 = try #require(frames.first { $0["cmd"] == .string("client-hello") && $0["role"] != nil })
        #expect(step1["features"] == .object([
            "hash": .string("app-hash"),
            "values": .object(["flagsFetch": .bool(false), "terminalHolder": .bool(true)]),
        ]))
        let step2 = try #require(frames.first { $0["cmd"] == .string("client-hello") && $0["proof"] != nil })
        #expect(step2["features"] == nil)
        #expect(hello.lastReply?.hash == "h2")
        #expect(hello.lastReply?.applied == ["flagsFetch"])
        #expect(hello.lastReply?.pending.isEmpty == true)
        #expect(hello.sessionValues == nil, "a handshake alone does not fix the session: the attached connection does")
        await connection.close()
    }

    private static func report(pending: [(String, app: Bool, daemon: Bool)]) throws -> ClientHelloRequest.FeatureReport {
        let rows = pending.map { #"{"name":"\#($0.0)","app":\#($0.app),"daemon":\#($0.daemon)}"# }
        let json = #"{"hash":"d","applied":[],"pending":[\#(rows.joined(separator: ","))]}"#
        return try JSONDecoder().decode(ClientHelloRequest.FeatureReport.self, from: Data(json.utf8))
    }

    /// The finding p12-perf-process-150 fixes: an app launched with `energySaver` on attaches to a daemon that
    /// started with it off. The daemon keeps off; the app's reader must run off too, never its launch value.
    @Test func aPendingBothFeatureRunsWithTheDaemonsValueInTheApp() throws {
        let hello = DaemonFeatureHello(hash: "app", values: ["energySaver": true, "terminalHolder": false])
        let seen = Seen([])
        hello.whenSessionValueKnown(of: "energySaver", launchValue: true) { value in seen.value.withLock { $0.append(value) } }
        hello.record(try Self.report(pending: [("energySaver", app: true, daemon: false)]))
        #expect(seen.value.withLock { $0 }.isEmpty, "the reader waits for the attached connection's answer")
        hello.settle()
        #expect(seen.value.withLock { $0 } == [false])
        #expect(hello.sessionValues == ["energySaver": false, "terminalHolder": false])
        // A reader that asks later gets the same session value at once.
        hello.whenSessionValueKnown(of: "energySaver", launchValue: true) { value in seen.value.withLock { $0.append(value) } }
        #expect(seen.value.withLock { $0 } == [false, false])
        // A later connection's answer (after a daemon restart) changes the report, never the session.
        hello.record(try Self.report(pending: []))
        hello.settle()
        #expect(hello.sessionValues?["energySaver"] == false)
        #expect(hello.lastReply?.pending.isEmpty == true)
    }

    /// No answer (an older daemon, or startup gave up): the app's own values are the session's.
    @Test func noAnswerKeepsTheAppsValues() {
        let hello = DaemonFeatureHello(hash: "app", values: ["energySaver": true])
        hello.record(nil)
        hello.settle()
        #expect(hello.sessionValues == ["energySaver": true])
        let seen = Seen([])
        hello.whenSessionValueKnown(of: "notInTheHello", launchValue: true) { value in seen.value.withLock { $0.append(value) } }
        #expect(seen.value.withLock { $0 } == [true])
    }

    @Test func aPageRelayHelloNeverCarriesFeatures() throws {
        let features = ClientHelloRequest.Features(hash: "h", values: ["flagsFetch": false])
        #expect(ClientHelloRequest(role: .pageRelay, page: "history", features: features).features == nil)
        #expect(ClientHelloRequest(role: .main, features: features).features == features)
    }
}

/// What a reader was called with: the `Mutex` in a class, since an escaping closure cannot capture a `Mutex`.
private nonisolated final class Seen: Sendable {
    let value: Mutex<[Bool]>

    init(_ initial: [Bool]) {
        value = Mutex(initial)
    }
}
