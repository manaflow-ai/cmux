@testable import CmuxNextApps
import Testing

/// The app's launch report for safe mode's crash loop rule (docs/cmux-next/extensions/safe-mode.md):
/// `safe_mode.launch_began` once per process, ahead of every mount (and `safe_mode.set {on: true}`
/// right after it when the launch key was held), and `safe_mode.launch_settled` once, only after a began.
@MainActor @Suite(.serialized) struct AppsSafeModeLaunchTests {
    private final class Transport: AppsTransport {
        var availability: AppsAvailability
        var onEvent: ((AppsTransportEvent) -> Void)?
        /// Every safe mode op and mount, in the order the supervisor got them.
        var calls: [String] = []

        init(availability: AppsAvailability) { self.availability = availability }

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply { AppsListReply(revision: 1, apps: []) }
        func sessionInfoPanels() async throws(AppsTransportError) -> [AppSessionInfoPanel] { [] }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw AppsTransportError(message: "unused")
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
            calls.append("mount")
        }
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            .null
        }
        func safeMode(_ op: String, args: AppJSON, origin: AppOrigin, timeout: Duration?) async throws(AppsTransportError) -> AppJSON {
            switch op {
            case "safe_mode.set": calls.append("set \(args["on"]?.boolValue == true ? "on" : "off") \(origin.rawValue)")
            case "safe_mode.launch_settled": calls.append("settled \(args["reason"]?.stringValue ?? "")")
            default: calls.append(op == "safe_mode.launch_began" ? "began" : op)
            }
            return .object([:])
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func settle(_ client: AppsClient) async {
        for _ in 0..<100 { await Task.yield() }
        await client.tail?.value
    }

    @Test func noKeyReportsBeganOnceAndNeverTurnsSafeModeOn() async {
        let transport = Transport(availability: .available(epoch: 1))
        let client = AppsClient(transport: transport)
        client.reportLaunchBegan(entersSafeMode: false)
        client.start()
        client.reportLaunchBegan(entersSafeMode: true)
        await Self.settle(client)
        #expect(transport.calls == ["began"])
    }

    @Test func heldKeyTurnsSafeModeOnRightAfterBegan() async {
        let transport = Transport(availability: .available(epoch: 1))
        let client = AppsClient(transport: transport)
        client.reportLaunchBegan(entersSafeMode: true)
        client.start()
        await Self.settle(client)
        #expect(transport.calls == ["began", "set on user"])
    }

    @Test func beganWaitsForTheFirstConnectionAndIsNotResentOnReconnect() async {
        let transport = Transport(availability: .unavailable(.notConnected))
        let client = AppsClient(transport: transport)
        client.reportLaunchBegan(entersSafeMode: true)
        client.start()
        await Self.settle(client)
        #expect(transport.calls.isEmpty)

        transport.onEvent?(.availability(.available(epoch: 1)))
        await Self.settle(client)
        #expect(transport.calls == ["began", "set on user"])

        // A reconnect is not a launch.
        transport.onEvent?(.availability(.unavailable(.notConnected)))
        transport.onEvent?(.availability(.available(epoch: 2)))
        await Self.settle(client)
        #expect(transport.calls == ["began", "set on user"])
    }

    @Test func settledIsSentOnceAfterBegan() async {
        let transport = Transport(availability: .available(epoch: 1))
        let client = AppsClient(transport: transport)
        client.reportLaunchBegan(entersSafeMode: false)
        client.start()
        await client.reportLaunchSettled(.frame)
        await client.reportLaunchSettled(.quit)
        await Self.settle(client)
        #expect(transport.calls == ["began", "settled frame"])
    }

    @Test func settledWithoutBeganSendsNothing() async {
        let transport = Transport(availability: .unavailable(.notConnected))
        let client = AppsClient(transport: transport)
        client.reportLaunchBegan(entersSafeMode: false)
        client.start()
        await client.reportLaunchSettled(.quit)
        await Self.settle(client)
        #expect(transport.calls.isEmpty)
    }

    @Test func leavingSafeModeCarriesTheOrigin() async throws {
        let transport = Transport(availability: .available(epoch: 1))
        let client = AppsClient(transport: transport)
        client.start()
        _ = try await client.setSafeMode(false, origin: .script)
        #expect(transport.calls == ["set off script"])
    }
}
