import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// A phone names a terminal by `surface_id` in whatever case it likes (the lookup is case-insensitive), and
/// sends any grid size. Each spelling used to open its own daemon attach, and a huge grid went straight to the
/// daemon.
struct PhoneTerminalStreamTests {
    private static let host = MobileCompatHostInfo(macDeviceID: "m", instanceTag: "t", bundleIdentifier: "com.cmuxterm.app.next",
                                                   displayName: "Mac", appVersion: "0", appBuild: "0", daemonLaneAvailable: true)
    private static let key: WorkspaceKey = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let terminal: TerminalID = "11111111111111111111111111111111"

    private static func tree(terminals: Int = 1) -> DaemonTree {
        let tabs = (0..<terminals).map { index in
            TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)), terminalID: TerminalID(rawValue: String(format: "%032x", index + 1)),
                        title: "shell \(index)", cwd: "/work")
        }
        let screen = ScreenSnapshot(id: 1, active: true, activePane: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: key, name: "api", screens: [screen])])
    }

    private static func session(terminals: Int = 1) -> (MobileCompatSession, FakeCompatBackend) {
        let backend = FakeCompatBackend(tree: tree(terminals: terminals))
        return (MobileCompatSession(backend: backend, host: host, emit: { _ in }, access: PhoneAccessGate()), backend)
    }

    private static func response(_ session: MobileCompatSession, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let raw = await session.handle(frame: frame)
        return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    private static func errorCode(_ answer: [String: Any]) -> String? { (answer["error"] as? [String: Any])?["code"] as? String }

    private static func surface(_ index: Int = 0) -> String {
        MobileCompatIDs.surfaceID(TerminalID(rawValue: String(format: "%032x", index + 1))) ?? ""
    }

    @Test func everySpellingOfASurfaceIdSharesOneAttach() async throws {
        let (session, backend) = Self.session()
        let id = Self.surface()
        for spelling in [id.uppercased(), id.lowercased(), id.uppercased(), id.lowercased()] {
            _ = try await Self.response(session, "mobile.terminal.replay", ["surface_id": spelling])
        }
        #expect(backend.liveChannelCount == 1, "each case variant left its own daemon attach")
        let closed = try await Self.response(session, "mobile.terminal.close", ["surface_id": id.lowercased()])
        #expect(closed["error"] == nil)
        _ = try await Self.response(session, "mobile.terminal.close", ["surface_id": id.uppercased()])
        #expect(backend.liveChannelCount == 0)
    }

    @Test(arguments: [(1_000_000_000, 24), (80, 1_000_000_000), (1001, 24), (80, 501)])
    func aGridBeyondTheLimitsIsRefusedBeforeTheDaemonSeesIt(cols: Int, rows: Int) async throws {
        let (session, backend) = Self.session()
        let params: [String: Any] = ["surface_id": Self.surface(), "viewport_columns": cols, "viewport_rows": rows]
        for method in ["mobile.terminal.viewport", "mobile.terminal.replay"] {
            let answer = try await Self.response(session, method, params)
            #expect(Self.errorCode(answer) == "invalid_params", "\(method): \(answer)")
        }
        #expect(backend.attachSizes.isEmpty)
    }

    @Test func theLimitsThemselvesAreAccepted() async throws {
        let (session, backend) = Self.session()
        let answer = try await Self.response(session, "mobile.terminal.viewport",
                                              ["surface_id": Self.surface(), "viewport_columns": 1000, "viewport_rows": 500])
        #expect(answer["error"] == nil, "\(answer)")
        #expect(backend.attachSizes == [CellSize(cols: 1000, rows: 500)])
    }

    @Test func aSessionHoldsAtMostThirtyTwoStreams() async throws {
        let (session, backend) = Self.session(terminals: 34)
        for index in 0..<32 {
            let answer = try await Self.response(session, "mobile.terminal.replay", ["surface_id": Self.surface(index)])
            #expect(answer["error"] == nil, "terminal \(index): \(answer)")
        }
        let refused = try await Self.response(session, "mobile.terminal.replay", ["surface_id": Self.surface(32)])
        #expect(Self.errorCode(refused) == "too_many_terminals", "\(refused)")
        #expect(backend.liveChannelCount == 32)
        // Replaying one it already streams is not a new stream.
        let again = try await Self.response(session, "mobile.terminal.replay", ["surface_id": Self.surface(3).lowercased()])
        #expect(again["error"] == nil, "\(again)")
        #expect(backend.liveChannelCount == 32)
    }
}
