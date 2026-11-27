import CMUXAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// A tagged dev build carries `X-Cmux-Build-Space: dev:<slug>` on every request and WebSocket upgrade the Mac's
/// cloud clients send (CloudConfiguration.buildSpace); nightly and stable builds send no such header; and a DEV build
/// with no usable tag is misconfigured: every client refuses its calls (CMUXBuildSpaceError), never nightly's data.
@Suite(.serialized)
struct CloudBuildSpaceTests {
    static let header = "X-Cmux-Build-Space"
    static let space = CMUXBuildSpace(devTag: "My_Tag 2")
    static let base = URL(string: "https://cloud-api-staging.cmux.dev") ?? URL(fileURLWithPath: "/dev/null")
    static let misconfigured = CMUXBuildSpaceState.misconfiguredDev(reason: "it has no tag")

    /// The tagged state, or nightly.
    static func state(_ tagged: Bool) -> CMUXBuildSpaceState {
        tagged ? CMUXBuildSpaceState(devBuild: true, devTag: "My_Tag 2") : .nightly
    }

    static func workerClient(_ buildSpace: CMUXBuildSpaceState) -> CloudDaemon {
        CloudDaemon.workerMachines(baseURL: Self.base, accessToken: { "session" }, teamID: { "team_1" },
                                   installToken: { "install" }, buildSpace: buildSpace)
    }

    @Test("The space is dev:<slug> of the build's tag")
    func spaceValue() {
        #expect(Self.space?.headerValue == "dev:my-tag-2")
        #expect(Self.state(true).space == Self.space)
    }

    // MARK: - The composition root's decision

    @Test("A tagged DEV or staging build has its tag's space", arguments: [
        ("com.cmuxterm.app.debug.feat-x", [:], "dev:feat-x"),
        ("com.cmuxterm.app.debug", ["CMUX_TAG": "My_Tag 2"], "dev:my-tag-2"),
        ("com.cmuxterm.app.staging.rel-check", [:], "dev:rel-check"),
    ] as [(String, [String: String], String)])
    func taggedBuilds(bundleID: String, bundled: [String: String], expected: String) {
        let configuration = CloudConfiguration.resolve(bundleID: bundleID, bundled: bundled, process: [:], isDebugBuild: true)
        #expect(configuration.buildSpace.space?.headerValue == expected)
    }

    @Test("Nightly, cmux NEXT, RC, release and untagged staging send no header", arguments: [
        "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app.rc", "com.cmuxterm.app.rc.cmux-next",
        "com.cmuxterm.app", "com.cmuxterm.app.staging",
    ])
    func nightlyBuilds(bundleID: String) {
        let configuration = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: false)
        #expect(configuration.buildSpace == .nightly)
    }

    @Test("A DEV build with no usable tag is misconfigured, never nightly", arguments: [
        ("com.cmuxterm.app.debug", [:]),
        ("com.cmuxterm.app.debug", ["CMUX_TAG": "___"]),
        ("com.cmuxterm.app.debug", ["CMUX_TAG": String(repeating: "a", count: 65)]),
    ] as [(String, [String: String])])
    func misconfiguredBuilds(bundleID: String, bundled: [String: String]) throws {
        let configuration = CloudConfiguration.resolve(bundleID: bundleID, bundled: bundled, process: [:], isDebugBuild: true)
        #expect(configuration.buildSpace.refusal != nil, "\(configuration.buildSpace)")
        #expect(configuration.buildSpace.space == nil)
        // Another selection keeps the decision.
        let selection = try #require(configuration.runtimeSelection)
        #expect(configuration.selecting(selection).buildSpace == configuration.buildSpace)
    }

    // MARK: - Clients

    @Test("A CloudDaemon with a build space or none runs its Worker call through cmux-tui (which sends the space)",
          arguments: [true, false])
    func workerClient(tagged: Bool) async throws {
        var daemon = Self.workerClient(Self.state(tagged))
        let seen = Seen()
        daemon.daemonCall = { input, _ in
            seen.input = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            return Data(#"{"ok":true,"body":[]}"#.utf8)
        }
        _ = try await daemon.listDomains()
        #expect(seen.input["call"] as? String == "vm.domains")
        #expect(seen.input["credential"] as? String == "session")
    }

    nonisolated final class Seen: @unchecked Sendable { var input: [String: Any] = [:] }

    @Test("CloudDaemon of a misconfigured dev build refuses before the child starts")
    func workerClientRefuses() async {
        var daemon = Self.workerClient(Self.misconfigured)
        daemon.daemonCall = { _, _ in
            Issue.record("a misconfigured build started a daemon call")
            return Data()
        }
        await #expect(throws: CMUXBuildSpaceError.self) { try await daemon.listDomains() }
        await #expect(throws: CMUXBuildSpaceError.self) { try await daemon.listNetworks() }
    }

    @Test("CloudOwnerAPIClient adds the header to its session's requests with a build space, none without", arguments: [true, false])
    func ownerClient(tagged: Bool) async throws {
        let owner = CloudOwnerAPIClient(baseURL: Self.base, accessToken: { "access" }, teamID: { "team_1" },
                                        buildSpace: Self.state(tagged))
        let request = try await owner.authorized(URLRequest(url: Self.base.appendingPathComponent("v1/handoffs")), access: "access")
        #expect(request.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team_1")
    }

    @Test("CloudOwnerAPIClient of a misconfigured dev build refuses every request")
    func ownerClientRefuses() async {
        let owner = CloudOwnerAPIClient(baseURL: Self.base, accessToken: { "access" }, teamID: { "team_1" },
                                        buildSpace: Self.misconfigured)
        await #expect(throws: CMUXBuildSpaceError.self) {
            _ = try await owner.authorized(URLRequest(url: Self.base.appendingPathComponent("v1/handoffs")), access: "access")
        }
        #expect(await owner.gitHubApp(team: "team_1") == .unknown)
    }

    @Test("The wire ticket request and the /v1/wire/cloud upgrade carry the header with a build space, none without",
          arguments: [true, false])
    func machineWire(tagged: Bool) throws {
        let space = Self.state(tagged)
        let ticket = try CloudMachineWire.ticketRequest(apiBaseURL: Self.base, access: "access", buildSpace: space)
        #expect(ticket.url?.absoluteString == "https://cloud-api-staging.cmux.dev/v1/wire/ticket")
        #expect(ticket.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        let socket = try CloudMachineWire.socketRequest(apiBaseURL: Self.base, ticket: "t1", team: "team_1", version: "1.0",
                                                        buildSpace: space)
        #expect(socket.url?.absoluteString == "wss://cloud-api-staging.cmux.dev/v1/wire/cloud")
        #expect(socket.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1, ticket.t1, team.team_1")
        #expect(socket.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
    }

    @Test("A misconfigured dev build mints no wire ticket and opens no /v1/wire/cloud socket")
    func machineWireRefuses() {
        #expect(throws: CMUXBuildSpaceError.self) {
            _ = try CloudMachineWire.ticketRequest(apiBaseURL: Self.base, access: "access", buildSpace: Self.misconfigured)
        }
        #expect(throws: CMUXBuildSpaceError.self) {
            _ = try CloudMachineWire.socketRequest(apiBaseURL: Self.base, ticket: "t1", team: nil, version: nil,
                                                   buildSpace: Self.misconfigured)
        }
    }

    @Test("The install transport and identity of a misconfigured dev build refuse: no request, no install token")
    func installRefuses() async throws {
        let transport = InstallHTTPTransport(baseURL: Self.base, buildSpace: Self.misconfigured, machineIO: nil)
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await transport.post("v1/install/token", json: Data(), bearer: nil, headers: [:]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-space-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MacInstallIdentity(store: .files(directory: root), transport: transport, deviceName: "Test Mac",
                                          clientVersion: nil, buildSpace: Self.misconfigured)
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await identity.installToken() }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await identity.installToken(team: "team_1") }
        #expect(identity.requestHeaders[Self.header] == nil)
    }

    @Test("A configuration holds no build space until the composition root sets one")
    func configurationHoldsTheSpace() {
        var configuration = CloudConfiguration.unavailable
        configuration.buildSpace = Self.state(true)
        #expect(configuration.buildSpace.space?.headerValue == "dev:my-tag-2")
        #expect(CloudConfiguration.unavailable.buildSpace == .nightly)
    }
}
