import Foundation
import Testing
@testable import CmuxControlSocket

/// Surface-domain overrides for the `surface.read_text` regression test (#6500).
///
/// Only the workspace-domain tests share `FakeWorkspaceControlCommandContext`, and
/// they never dispatch `surface.*` methods, so these surface overrides do not leak
/// into any other test. The `includeScrollback` argument is encoded into the return
/// value so the test needs no stored capture state: a forced scrollback produces a
/// distinct error that the coordinator surfaces as `internal_error`.
extension FakeWorkspaceControlCommandContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ControlSurfaceReadTextResolution {
        if includeScrollback {
            return .internalError(message: "scrollback-forced")
        }
        return .read(
            text: "viewport-tail",
            base64: Data("viewport-tail".utf8).base64EncodedString(),
            windowID: nil,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
    }
}

@MainActor
@Suite("ControlCommandCoordinator surface.read_text")
struct ControlCommandCoordinatorSurfaceReadTextTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    /// Regression test for https://github.com/manaflow-ai/cmux/issues/6500.
    ///
    /// `surface.read_text --lines N` (without `scrollback: true`) must NOT force
    /// `includeScrollback = true` on the context. The pre-fix coordinator
    /// unconditionally set `includeScrollback = true` whenever `lineLimit` was
    /// non-nil, triggering full-history `PageFormatter` work on the main actor.
    /// The fake context returns `internal_error` when scrollback is forced, so this
    /// test is red without the fix and green with it.
    @Test func readTextWithLinesDoesNotForceScrollback() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("surface.read_text", ["lines": .int(5)]))

        guard case .ok(.object(let payload)) = result,
              case .string(let text) = payload["text"] else {
            Issue.record("expected .ok with text payload (scrollback was forced). Got: \(String(describing: result))")
            return
        }
        #expect(text == "viewport-tail")
    }

    /// Explicit `scrollback: true` still reaches the context with
    /// `includeScrollback = true` — the fix only removes the *forced* scrollback
    /// for `--lines N`, not the explicit opt-in.
    @Test func readTextWithExplicitScrollbackStillForcesIt() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("surface.read_text", ["scrollback": .bool(true)]))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected .err (fake returns internal_error for scrollback). Got: \(String(describing: result))")
            return
        }
        #expect(code == "internal_error")
    }

    /// Without `--lines` and without `--scrollback`, `includeScrollback` stays
    /// `false` — the baseline that the fix preserves.
    @Test func readTextWithoutLinesOrScrollbackStaysFalse() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request("surface.read_text"))

        guard case .ok(.object(let payload)) = result,
              case .string(let text) = payload["text"] else {
            Issue.record("expected .ok with text payload. Got: \(String(describing: result))")
            return
        }
        #expect(text == "viewport-tail")
    }
}
