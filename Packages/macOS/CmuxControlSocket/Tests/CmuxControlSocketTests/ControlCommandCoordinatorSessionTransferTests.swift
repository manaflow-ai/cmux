import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator session import/export")
struct ControlCommandCoordinatorSessionTransferTests {
    private func call(
        _ method: String,
        _ params: [String: JSONValue],
        context: FakeSessionTransferControlCommandContext
    ) -> ControlCallResult {
        ControlCommandCoordinator(context: context)
            .handle(ControlRequest(id: .int(1), method: method, params: params))
            ?? .err(code: "unhandled", message: method, data: nil)
    }

    @Test func importFromChannelForwardsSourceAndReportsWindows() throws {
        let context = FakeSessionTransferControlCommandContext()
        context.importResolution = .restored(
            sourcePath: "/support/cmux/session-com.cmuxterm.app.nightly.json",
            windowCount: 2,
            heldBackResumeCount: 0,
            droppedRemoteWorkspaceCount: 0
        )

        let result = call("session.import", ["source": .string(" nightly ")], context: context)

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(context.importSources == [.channel("nightly")])
        #expect(payload["restored"] == .bool(true))
        #expect(payload["source_path"] == .string("/support/cmux/session-com.cmuxterm.app.nightly.json"))
        #expect(payload["window_count"] == .int(2))
        #expect(payload["trusted"] == .bool(true))
        #expect(payload["held_back_resume_count"] == .int(0))
    }

    @Test func importFromAbsolutePathForwardsFileSourceAndReportsHeldBackResumes() {
        let context = FakeSessionTransferControlCommandContext()
        context.importResolution = .restored(
            sourcePath: "/Users/me/session.json",
            windowCount: 1,
            heldBackResumeCount: 3,
            droppedRemoteWorkspaceCount: 1
        )

        let result = call("session.import", ["path": .string("/Users/me/session.json")], context: context)

        #expect(context.importSources == [.file(path: "/Users/me/session.json")])
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["trusted"] == .bool(false))
        #expect(payload["held_back_resume_count"] == .int(3))
        #expect(payload["dropped_remote_workspace_count"] == .int(1))
    }

    @Test(arguments: [
        [String: JSONValue](),
        ["path": .string("/a.json"), "source": .string("nightly")],
        ["path": .string("relative.json")],
        ["source": .string("   ")],
    ])
    func importRejectsBadParamsBeforeTouchingTheApp(params: [String: JSONValue]) {
        let context = FakeSessionTransferControlCommandContext()

        let result = call("session.import", params, context: context)

        guard case .err(let code, _, _) = result else {
            Issue.record("expected invalid_params, got \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.importSources.isEmpty)
    }

    @Test func importFailureCarriesCodeMessageAndPath() {
        let context = FakeSessionTransferControlCommandContext()
        context.importResolution = .failed(code: "unsupported", message: "newer schema", path: "/x.json")

        let result = call("session.import", ["path": .string("/x.json")], context: context)

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected error, got \(result)")
            return
        }
        #expect(code == "unsupported")
        #expect(message == "newer schema")
        #expect(data == .object(["path": .string("/x.json")]))
    }

    @Test func exportForwardsPathAndForceFlag() throws {
        let context = FakeSessionTransferControlCommandContext()

        let result = call("session.export", ["path": .string("/tmp/out.json"), "force": .bool(true)], context: context)

        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(context.exportRequests.map(\.path) == ["/tmp/out.json"])
        #expect(context.exportRequests.map(\.overwrite) == [true])
        #expect(payload["exported"] == .bool(true))
        #expect(payload["path"] == .string("/tmp/out.json"))
        #expect(payload["source_path"] == .string("/tmp/src.json"))
    }

    @Test func exportDefaultsToNoOverwriteAndRequiresAbsolutePath() {
        let context = FakeSessionTransferControlCommandContext()

        _ = call("session.export", ["path": .string("/tmp/out.json")], context: context)
        let relative = call("session.export", ["path": .string("out.json")], context: context)
        let missing = call("session.export", [:], context: context)

        #expect(context.exportRequests.map(\.overwrite) == [false])
        for result in [relative, missing] {
            guard case .err(let code, _, _) = result else {
                Issue.record("expected invalid_params, got \(result)")
                continue
            }
            #expect(code == "invalid_params")
        }
    }
}
