import Foundation
import Testing
@testable import CmuxNextDaemon

/// `LayoutSizeCommands`: the daemon commands for the values one resize gesture ends with. One value goes as its own
/// command. More go to a daemon with `layout-sizes-batch-v1` as one `set-layout-sizes` (one commit, every value or
/// none); a daemon without it, and a change of more values than one command takes, gets each value's own command in
/// order. Every command carries the gesture's one transaction (one undo step).
struct LayoutSizeCommandsTests {
    private static let values: [SetLayoutSizesRequest.Value] = [
        .width(pane: PaneID(rawValue: 2), 0.25), .width(pane: PaneID(rawValue: 5), 0.75), .ratio(SplitID(rawValue: 4), 0.5),
    ]

    @Test func aDaemonWithTheBatchGetsOneCommandForEveryValue() {
        let commands = LayoutSizeCommands(Self.values, transaction: 31, batch: true)
        #expect(commands.commands == [.batch(Self.values)])
        #expect(commands.transaction == 31)
        #expect(commands.label == "set-layout-sizes")
    }

    @Test func oneValueGoesAsItsOwnCommandOnEveryDaemon() {
        for batch in [false, true] {
            let ratio = LayoutSizeCommands([.ratio(SplitID(rawValue: 4), 0.5)], transaction: 9, batch: batch)
            #expect(ratio.commands == [.single(.ratio(SplitID(rawValue: 4), 0.5))])
            #expect(ratio.label == "set-split-ratio")
            let width = LayoutSizeCommands([.width(pane: PaneID(rawValue: 2), 0.25)], transaction: 9, batch: batch)
            #expect(width.commands == [.single(.width(pane: PaneID(rawValue: 2), 0.25))])
            #expect(width.label == "set-viewport-pane-width")
        }
    }

    @Test func aDaemonWithoutTheBatchGetsEachValuesOwnCommandInOrder() {
        let commands = LayoutSizeCommands(Self.values, transaction: 31, batch: false)
        #expect(commands.commands == Self.values.map(LayoutSizeCommands.Command.single))
        #expect(commands.transaction == 31)
        #expect(commands.label == "set-layout-sizes")
    }

    @Test func moreValuesThanOneCommandTakesGoAsTheirOwnCommands() {
        let most = (1...SetLayoutSizesRequest.limit).map { SetLayoutSizesRequest.Value.width(pane: PaneID(rawValue: UInt64($0)), 0.5) }
        #expect(most.count == 64)
        #expect(LayoutSizeCommands(most, transaction: 1, batch: true).commands == [.batch(most)])
        let over = most + [.ratio(SplitID(rawValue: 4), 0.5)]
        #expect(LayoutSizeCommands(over, transaction: 1, batch: true).commands == over.map(LayoutSizeCommands.Command.single))
    }

    @Test func noValuesAreNoCommand() {
        #expect(LayoutSizeCommands([], transaction: 1, batch: true).commands.isEmpty)
        #expect(LayoutSizeCommands([], transaction: 1, batch: false).commands.isEmpty)
    }

    /// A request that only the fixture daemon of the test below knows: the size commands it got.
    private struct CapturedSizeCalls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-size-calls"
    }

    /// The commands on a real connection over a fixture bridge (no daemon of a person starts): one `set-layout-sizes`
    /// with every value for a daemon that serves the batch, each value's own command for one that does not, all under
    /// the gesture's transaction.
    @Test(arguments: [false, true])
    func theCommandsReachTheDaemonUnderTheGesturesTransaction(serves: Bool) async throws {
        let script = #"""
        import json, sys
        serves = sys.argv[1] == 'yes'
        calls = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            cmd = frame.get('cmd')
            result = {}
            if cmd == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'sizes-boot',
                    'capabilities':['layout-sizes-batch-v1'] if serves else []}
            elif cmd in ('set-layout-sizes', 'set-viewport-pane-width', 'set-split-ratio'):
                calls.append(frame)
            elif cmd == 'test-size-calls':
                result = calls
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge.fakePython(["-c", script, serves ? "yes" : "no"])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-sizes-test-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            try await LayoutSizeCommands(Self.values, transaction: 31, batch: serves).send(on: connection)
            let captured = try await connection.request(CapturedSizeCalls())
            let calls = try #require(captured.arrayValue)
            let commands = calls.compactMap { $0["cmd"] }
            #expect(calls.allSatisfy { $0["transaction"] == .number(31) }, "a command left the gesture's transaction: \(calls)")
            if serves {
                #expect(commands == [JSONValue.string("set-layout-sizes")])
                #expect(calls.first?["values"] == .array([
                    .object(["pane": .number(2), "width": .number(0.25)]), .object(["pane": .number(5), "width": .number(0.75)]),
                    .object(["split": .number(4), "ratio": .number(0.5)]),
                ]))
            } else {
                #expect(commands == [JSONValue.string("set-viewport-pane-width"), .string("set-viewport-pane-width"), .string("set-split-ratio")])
                #expect(calls.compactMap { $0["pane"] } == [JSONValue.number(2), .number(5)])
                #expect(calls.last?["split"] == .number(4))
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}
