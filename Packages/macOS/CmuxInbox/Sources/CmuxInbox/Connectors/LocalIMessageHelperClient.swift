public import Foundation

/// Local process adapter for `tools/cmux-imsg`.
public struct LocalIMessageHelperClient: IMessageHelperClient {
    private let candidatePaths: [URL]
    private let runner: any IMessageHelperRunning

    /// Creates a helper client.
    /// - Parameters:
    ///   - candidatePaths: Candidate helper executable paths.
    ///   - runner: Helper process runner.
    public init(
        candidatePaths: [URL] = Self.defaultHelperPaths(),
        runner: any IMessageHelperRunning = ProcessIMessageHelperRunner()
    ) {
        self.candidatePaths = candidatePaths
        self.runner = runner
    }

    /// Candidate helper binary locations for local development and bundled builds.
    public static func defaultHelperPaths() -> [URL] {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            current.appendingPathComponent("tools/cmux-imsg/cmux-imsg"),
            current.appendingPathComponent("tools/cmux-imsg/.build/release/cmux-imsg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cmux-imsg"),
        ]
    }

    /// Returns helper status or a missing-helper status.
    public func status() async -> IMessageHelperStatus {
        guard let helper = helperURL() else {
            return IMessageHelperStatus(
                ok: false,
                message: "cmux-imsg helper is not installed",
                permissionDenied: false,
                helperInstalled: false
            )
        }
        do {
            let data = try await runner.run(helperURL: helper, arguments: ["status", "--json"], stdin: nil)
            return try IMessageHelperJSONAdapter.status(from: data)
        } catch {
            return IMessageHelperStatus(ok: false, message: String(describing: error), permissionDenied: false)
        }
    }

    /// Reads recent helper messages.
    public func recent(cursor: String?) async throws -> InboxConnectorSyncResult {
        guard let helper = helperURL() else {
            let status = InboxConnectorStatus(
                source: .imessage,
                accountID: "local",
                displayName: "Messages",
                status: .missingHelper,
                message: "cmux-imsg helper is not installed",
                capabilities: IMessageHelperConnector.defaultCapabilities
            )
            return InboxConnectorSyncResult(status: status)
        }
        var args = ["recent", "--json"]
        if let cursor { args.append(contentsOf: ["--cursor", cursor]) }
        let data = try await runner.run(helperURL: helper, arguments: args, stdin: nil)
        return try IMessageHelperJSONAdapter.syncResult(from: data)
    }

    /// Sends an approved reply through the helper.
    public func sendApprovedReply(draft: InboxDraft, thread: InboxThread) async throws {
        guard let helper = helperURL() else {
            throw InboxError.connectorUnavailable("cmux-imsg helper is not installed")
        }
        let payload = try JSONEncoder().encode(["thread_id": thread.externalThreadID, "body": draft.body])
        _ = try await runner.run(helperURL: helper, arguments: ["send", "--json"], stdin: payload)
    }

    private func helperURL() -> URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
