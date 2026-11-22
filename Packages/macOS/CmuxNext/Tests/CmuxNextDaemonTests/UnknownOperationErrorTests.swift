import Foundation
import Testing
@testable import CmuxNextDaemon

/// An older daemon refuses a `cmux.protocol/2` operation it does not have as an invalid envelope
/// (`validation.invalid`, serde's "unknown variant"). The app tells that apart from a refusal of
/// the request's values, so it can ask for a restart of the background service.
@Suite struct UnknownOperationErrorTests {
    @Test func anUnknownVariantRefusalIsAnUnknownOperation() {
        let old = DaemonError.command(
            cmd: "workspace.agent_folder.set", message: "invalid request envelope", code: "validation.invalid",
            details: .object(["error": .string("unknown variant `workspace.agent_folder.set`, expected one of `workspace.update`")]),
            retryable: false)
        #expect(old.isUnknownOperation)
        let value = DaemonError.command(cmd: "workspace.agent_folder.set", message: "path must name a folder",
                                        code: "validation.invalid", details: .object(["field": .string("path")]), retryable: false)
        #expect(!value.isUnknownOperation)
        #expect(!DaemonError.notConnected.isUnknownOperation)
    }

    @Test func theAgentFolderCapabilityIsOptionalForTheBundledDaemon() {
        #expect(DaemonCapabilities.shared.workspaceAgentFolder == "workspace-agent-folder-v1")
        #expect(DaemonCapabilities.shared.optional.contains(DaemonCapabilities.shared.workspaceAgentFolder))
    }
}
