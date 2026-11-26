import Foundation
package import CmuxNextDaemon
package import CmuxNextPages
import CmuxNextSettings
import CmuxNextWindowRules

package extension PageDescriptor {
    nonisolated static let terminalHistory = PageDescriptor(
        id: "cmux.terminal-history", resource: "terminal-history",
        namespaces: [TerminalHistoryBridge.namespace], ownsSearchField: true, followsChatZoom: true)
}

/// The hook identifies the transcript. The page receives a capability for this one chat:
/// neither a file path nor a writable agent session crosses the page bridge.
package nonisolated struct TerminalHistorySource: Equatable, Sendable {
    package let key: String
    let cwd: String?

    package init(key: String, cwd: String?) {
        self.key = key
        self.cwd = cwd
    }

    package static func chatKey(_ status: AgentStatus?) -> String? {
        guard let status, let session = status.harnessSessionID else { return nil }
        switch WindowRules().agentHarness(status.agent) {
        case "claude": return "claude-code:" + session
        case "codex": return "codex:" + session
        default: return nil
        }
    }

    @MainActor
    package func page(environment: AcpmuxEnvironment?, host: any AgentPaneHostProviding) -> PageWebView? {
        let provider = TerminalHistoryBridge(source: self, environment: environment, host: host)
        return PageWebView(descriptor: .terminalHistory, routes: [PageRoute(prefix: TerminalHistoryBridge.namespace, provider: provider)])
    }

    @concurrent func read(_ method: AcpmuxHarnessMethod, environment: AcpmuxEnvironment,
              params: [String: any Sendable]) async throws -> CmuxNextSettings.JSONValue {
        var request = params
        request["key"] = key
        if let cwd { request["cwd"] = cwd }
        let data = try await environment.harness(method, params: request)
        return try CmuxNextSettings.JSONValue.parse(data)
    }
}

@MainActor
private final class TerminalHistoryBridge: PageProvider {
    nonisolated static let namespace = "cmux.terminal_history."
    let source: TerminalHistorySource
    private let environment: AcpmuxEnvironment?
    private let host: any AgentPaneHostProviding
    init(source: TerminalHistorySource, environment: AcpmuxEnvironment?, host: any AgentPaneHostProviding) {
        self.source = source
        self.environment = environment
        self.host = host
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let environment else { throw PageError(code: "unavailable", message: String(localized: "terminalHistory.unavailable", defaultValue: "Chat history is unavailable.", bundle: .localizedModule)) }
        let method: AcpmuxHarnessMethod
        var request: [String: any Sendable] = [:]
        switch op {
        case Self.namespace + "page":
            method = .terminalTranscriptPage
            if let field = params["rawStart"] {
                guard let start = field.intValue, start >= 0,
                      let end = params["rawEnd"]?.intValue, end > start,
                      let offset = params["rawOffset"]?.intValue, (start..<end).contains(offset),
                      let before = params["before"]?.intValue, end <= before else { throw PageError.invalidParams("raw range") }
                request["rawStart"] = start
                request["rawEnd"] = end
                request["rawOffset"] = offset
            } else if let row = params["turn"] {
                guard let turn = row.intValue, turn >= 0,
                      let role = params["role"]?.stringValue, ["user", "assistant"].contains(role),
                      let offset = params["offset"]?.intValue, offset >= 0,
                      params["before"]?.intValue != nil else { throw PageError.invalidParams("turn") }
                request["turn"] = turn
                request["role"] = role
                request["offset"] = offset
            }
        case Self.namespace + "find":
            guard let query = params["query"]?.stringValue else { throw PageError.invalidParams("query") }
            method = .terminalTranscriptFind
            request["query"] = query
        default: throw PageError.unknownOp(op)
        }
        if let boundary = params["completeThrough"], !boundary.isNull {
            guard let offset = boundary.intValue, offset >= 0 else { throw PageError.invalidParams("completeThrough") }
            request["completeThrough"] = offset
        }
        if let before = params["before"], !before.isNull {
            guard let offset = before.intValue, offset >= 0 else { throw PageError.invalidParams("before") }
            request["before"] = offset
        }
        do {
            return try await source.read(method, environment: environment, params: request)
        } catch let error as AcpmuxRPCError where error.isUnreachable {
            try await host.prewarm()
            return try await source.read(method, environment: environment, params: request)
        }
    }
}
