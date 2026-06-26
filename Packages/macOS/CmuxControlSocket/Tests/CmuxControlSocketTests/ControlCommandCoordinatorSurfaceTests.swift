import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.report_pwd", params: params)
    }

    private func readTextRequest(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.read_text", params: params)
    }

    @Test func reportPWDRejectsConflictingPathAliases() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar"),
            "cwd": .string("/srv/work/other"),
        ]))

        #expect(result == .err(code: "invalid_params", message: "Conflicting path parameters", data: nil))
        #expect(context.reportedPWD?.path == nil)
    }

    @Test func reportPWDPreservesExactPathWhitespace() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar "),
        ]))

        #expect(context.reportedPWD?.path == "/srv/work/bar ")
    }

    // MARK: - read_text: `lines` and `scrollback` are orthogonal

    /// Regression for https://github.com/manaflow-ai/cmux/issues/6500: a bounded
    /// `--lines N` read with no explicit `scrollback` must NOT force a full
    /// scrollback materialization. The coordinator used to set
    /// `includeScrollback = true` whenever `lines` was present, so a 4-line poll
    /// (e.g. the tmux-compat HUD probe) pulled and formatted the entire terminal
    /// history on the main actor before trimming. With the fix the coordinator
    /// forwards `includeScrollback: false`, keeping the read viewport-bounded.
    @Test func readTextWithLinesButNoScrollbackDoesNotForceScrollback() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(readTextRequest([
            "surface_id": .string(UUID().uuidString),
            "lines": .int(4),
        ]))

        #expect(context.readTextInvocation?.includeScrollback == false)
        #expect(context.readTextInvocation?.lineLimit == 4)
    }

    @Test func readTextWithScrollbackAndLinesKeepsScrollback() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(readTextRequest([
            "surface_id": .string(UUID().uuidString),
            "lines": .int(200),
            "scrollback": .bool(true),
        ]))

        #expect(context.readTextInvocation?.includeScrollback == true)
        #expect(context.readTextInvocation?.lineLimit == 200)
    }

    @Test func readTextWithScrollbackOnlyKeepsScrollbackAndNoLineLimit() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(readTextRequest([
            "surface_id": .string(UUID().uuidString),
            "scrollback": .bool(true),
        ]))

        #expect(context.readTextInvocation?.includeScrollback == true)
        #expect(context.readTextInvocation?.lineLimit == nil)
    }

    @Test func readTextWithNoArgsStaysViewportBounded() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(readTextRequest([
            "surface_id": .string(UUID().uuidString),
        ]))

        #expect(context.readTextInvocation?.includeScrollback == false)
        #expect(context.readTextInvocation?.lineLimit == nil)
    }

    @Test func readTextRejectsNonPositiveLineLimitBeforeReading() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(readTextRequest([
            "surface_id": .string(UUID().uuidString),
            "lines": .int(0),
        ]))

        #expect(result == .err(code: "invalid_params", message: "lines must be greater than 0", data: nil))
        #expect(context.readTextInvocation == nil)
    }
}
