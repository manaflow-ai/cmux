import Foundation
import Testing
@testable import CmuxNextApps
@testable import CmuxNextDaemon

/// Real pinned wire carriers and the store's stamped fanout, with explicit native barriers.
@MainActor
final class InventoryProviderBridgeFixture {
    struct Command: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-control"
        var kind: String
        var count: Int = 0
    }
    let connection: DaemonConnection
    let events = DaemonSideEvents()
    let machine: ResourceID = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    var routes: [AgentInventoryWatchRoute] = []
    var pump: Task<Void, Never>?
    var bridge: AgentInventoryProviderBridge!
    var session: AppProviderSession!
    var applyControlStamp = true
    private let handshakes = AsyncStream.makeStream(of: DaemonEventEnvelope.self)

    init(mode: String = "normal") {
        let carrier = DaemonBridge.fakePython(["-c", Self.script, mode])
        connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-provider-bridge-\(UUID().uuidString).sock", bridge: carrier),
                                      configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        bridge = AgentInventoryProviderBridge { [weak self] in self?.routes ?? [] }
    }

    func start() async throws {
        try await connection.start()
        let events = events, connection = connection, sink = handshakes.continuation
        // task-owner: fixture pump is cancelled and its bounded subprocess closed by finish.
        pump = Task { [weak self] in
            do {
                for try await envelope in connection.events {
                    if case .connected = envelope.event {
                        if self?.applyControlStamp == true { events.noteControl(envelope) }
                        sink.yield(envelope)
                    }
                    events.deliver(envelope.event, envelope: envelope)
                }
            }
            catch { }
        }
        for await _ in handshakes.stream { break }
        routes = [.init(machine: machine, connection: connection, epoch: 1, events: events)]
        session = try await AppProviderSession(connection: connection)
        bridge.begin(session)
        let token = events.subscribeEnvelopes { [weak self] in self?.bridge.handle($0) }
        providerToken = token
        let snapshot = try await session.register(families: ["agent_cli", "action"])
        bridge.registered(session, snapshot: snapshot)
    }
    private var providerToken: UInt64?

    func finish() async {
        bridge.stop()
        if let providerToken { events.unsubscribe(providerToken) }
        pump?.cancel()
        await connection.close()
    }

    func wait(_ kind: String, _ count: Int = 1) async throws {
        _ = try await connection.request(Command(kind: kind, count: count), timeout: .seconds(10))
    }

    func reconnect() async throws {
        let serial = try #require(session?.serial)
        _ = try await connection.request(Command(kind: "drop"))
        for await envelope in handshakes.stream where envelope.connectionSerial > serial { return }
        throw DaemonError.notConnected
    }

    func state() async throws -> [JSONValue] {
        try await connection.request(Command(kind: "state")).arrayValue ?? []
    }

    func demand(_ sequence: UInt64, _ enabled: Bool, source: UUID? = nil, serial: UInt64? = nil) {
        let line = Data("{\"sequence\":\(sequence),\"enabled\":\(enabled)}".utf8)
        bridge.handle(.init(sequence: (serial ?? session.serial) << 40 | 10,
                            event: .decode(name: "apps-agent-inventory-demand", line: line), sourceID: source ?? session.sourceID))
    }

    func changed(revision: UInt64, source: UUID? = nil, serial: UInt64? = nil,
                 watch: String = "inventory_watch_0123456789abcdef0123456789abcdef") {
        let line = Data("{\"machine\":\"\(machine.rawValue)\",\"watch_id\":\"\(watch)\",\"revision\":\(revision)}".utf8)
        let event = DaemonEvent.decode(name: "agent-inventory-changed", line: line)
        let envelope = DaemonEventEnvelope(sequence: (serial ?? session.serial) << 40 | 11, event: event, sourceID: source ?? connection.eventSourceID)
        events.deliver(event, envelope: envelope)
    }

    func ended() {
        let line = Data("{\"machine\":\"\(machine.rawValue)\",\"watch_id\":\"inventory_watch_0123456789abcdef0123456789abcdef\",\"reason\":\"agent_inventory.owner_changed\"}".utf8)
        let event = DaemonEvent.decode(name: "agent-inventory-watch-ended", line: line)
        events.deliver(event, envelope: .init(sequence: session.serial << 40 | 12, event: event, sourceID: connection.eventSourceID))
    }

    static let script = #"""
    import json, sys, uuid
    mode = sys.argv[1]
    boot = str(uuid.uuid4())
    calls, waiting, pending = [], [], None
    machine = 'machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    watch = 'inventory_watch_0123456789abcdef0123456789abcdef'
    def reply(frame, data={}):
        print(json.dumps({'id':frame.get('id'), 'ok':True, 'data':data}), flush=True)
    def count(kind):
        return sum(1 for c in calls if c['kind'] == kind)
    def release_waiters():
        global waiting
        keep=[]
        for w in waiting:
            if count(w['kind']) >= w['count']: reply(w)
            else: keep.append(w)
        waiting=keep
    def receipt(): return {'machine':machine, 'watch_id':watch, 'revision':1}
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        f=json.loads(line); cmd=f.get('cmd')
        if cmd == 'identify':
            caps=['apps-v1','agent-inventory-watch-fence-v1']
            if mode != 'legacy': caps.append('agent-cli-app-provider-v1')
            if mode not in ['legacy','provider']: caps.append('agent-cli-app-invalidation-v1')
            if mode == 'retry-first': caps.append('agent-inventory-watch-admission-v1')
            reply(f, {'app':'cmux-tui','protocol':12,'generation':boot, 'machine_id':machine,'capabilities':caps})
        elif cmd == 'apps-provider-register':
            calls.append({'kind':'register','opted_in':f.get('inventory_watch') is True,'families':f['families']})
            if mode == 'early': print(json.dumps({'event':'apps-agent-inventory-demand','sequence':9007199254740993,'enabled':True}), flush=True)
            reply(f, {'families':f['families'],'inventory_demand':{'sequence':1,'enabled':False}})
        elif cmd == 'agent-inventory-watch':
            calls.append({'kind':'enable' if f['enabled'] else 'disable', **f})
            if f['enabled'] and mode == 'retry-first' and count('enable') == 1:
                print(json.dumps({'id':f['id'],'ok':False,'error':'agent_inventory.unavailable','error_code':'agent_inventory.unavailable',
                    'data':{'machine':machine,'admission':'not_admitted'}}), flush=True)
            elif f['enabled'] and mode == 'hold': pending=f
            else: reply(f, receipt() if f['enabled'] else {})
            release_waiters()
        elif cmd == 'apps-agent-inventory-changed':
            calls.append({'kind':'invalidate','sequence':str(f['demand_sequence']), 'strict':set(f) == {'id','cmd','demand_sequence'}})
            reply(f); release_waiters()
        elif cmd == 'test-control':
            if f['kind'] == 'drop': reply(f); break
            elif f['kind'] == 'state': reply(f, calls)
            elif f['kind'] == 'release':
                if pending is not None: reply(pending, receipt()); pending=None
                reply(f)
            elif count(f['kind']) >= f['count']: reply(f)
            else: waiting.append(f)
        else: reply(f)
    """#
}
