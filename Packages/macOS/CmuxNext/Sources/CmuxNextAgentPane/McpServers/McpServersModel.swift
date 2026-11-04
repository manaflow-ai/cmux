public import Foundation
import Observation

/// The state of Settings > MCP Servers: the person's MCP connections and the result of their last
/// click. Every change is a method the view calls from a person's click; a deep link
/// (`cmux mcp auth|key|policy NAME`) only selects a connection with ``focus(_:)`` and changes
/// nothing. After each change the model reads the list again from acpmux, the source of truth;
/// it keeps no optimistic copy.
///
/// A key goes from the view's field straight into ``saveKey(_:for:)`` and on to the service; the
/// model keeps no copy of it.
///
/// ```swift
/// let model = McpServersModel(service: AcpmuxMcpServersService { await AcpmuxPersonLine.open(env) },
///                             openURL: { url in pane.newBrowserTab(url: url) })
/// await model.reload()
/// ```
@MainActor
@Observable
public final class McpServersModel {
    /// The connections of the last read, in the daemon's order.
    public private(set) var connections: [McpServerConnection] = []
    /// True until the first read finished.
    public private(set) var isLoading = true
    /// The message of the last request, nil when there is none.
    public private(set) var notice: McpServersNotice?
    /// Connections with a request in flight: their controls wait.
    public private(set) var busy: Set<String> = []
    /// The audit lines while the audit log shows, else nil.
    public private(set) var auditLines: [String]?
    /// The connection a deep link selected (its id), shown first and marked.
    public private(set) var focusedID: String?
    /// A deep link's name or id that the last read did not know, else nil.
    public private(set) var unknownReference: String?

    @ObservationIgnored private let service: any McpServersServing
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var pendingFocus: String?

    /// The audit lines the log shows.
    public static let auditLimit = 200

    /// - Parameters:
    ///   - service: acpmux's person methods (``AcpmuxMcpServersService``, or a fake in tests).
    ///   - openURL: Opens a sign-in page in a cmux browser tab.
    public init(service: any McpServersServing, openURL: @escaping @MainActor (URL) -> Void) {
        self.service = service
        self.openURL = openURL
    }

    /// Reads the list again. A failed read keeps the last list and sets ``notice``.
    public func reload() async {
        defer { isLoading = false }
        do {
            connections = try await service.connections()
            resolveFocus()
        } catch {
            notice = Self.notice(for: error)
        }
    }

    /// Selects the connection `reference` names (its name or id) once the list has it. Changes
    /// nothing in acpmux: the person still clicks.
    public func focus(_ reference: String?) {
        let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFocus = reference?.isEmpty == false ? reference : nil
        if pendingFocus == nil {
            focusedID = nil
            unknownReference = nil
            return
        }
        if !isLoading { resolveFocus() }
    }

    /// Sets the policy of `tool` on connection `id`.
    public func setPolicy(_ policy: McpToolPolicy, tool: String, of id: String) async {
        await run(id) { try await self.service.setPolicy(policy, tool: tool, connection: id) }
    }

    /// Removes connection `id` and its secret.
    public func remove(_ id: String) async {
        let removed = await run(id) { try await self.service.remove(connection: id) }
        if removed {
            notice = .removed
            if focusedID == id { focusedID = nil }
        }
    }

    /// Starts the sign-in of connection `id` and opens its page in a cmux browser tab.
    public func signIn(_ id: String) async {
        var page: URL?
        let started = await run(id) { page = try await self.service.signIn(connection: id) }
        guard started, let page else { return }
        openURL(page)
        notice = .signInOpened
    }

    /// Gives connection `id` the key the person typed. The view clears its field after this call
    /// whatever the outcome.
    /// - Returns: True when the server took the key.
    @discardableResult
    public func saveKey(_ key: String, for id: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        var outcome = McpKeyOutcome.refused
        let sent = await run(id) { outcome = try await self.service.setKey(key, connection: id) }
        guard sent else { return false }
        notice = outcome == .connected ? .keySaved : .keyRefused
        return outcome == .connected
    }

    /// Approves the held tools of connection `id` (new or changed after a key or a sign-in), the
    /// person's click on Approve Changed Tools. A deep link never calls it.
    public func approveTools(_ id: String) async {
        let approved = await run(id) { _ = try await self.service.approveTools(connection: id) }
        if approved { notice = .toolsApproved }
    }

    /// Reads the newest audit lines and shows the log.
    public func showAudit() async {
        do {
            auditLines = try await service.audit(limit: Self.auditLimit)
        } catch {
            notice = Self.notice(for: error)
        }
    }

    /// Hides the audit log.
    public func hideAudit() {
        auditLines = nil
    }

    /// Clears the message.
    public func dismissNotice() {
        notice = nil
    }

    /// Runs one change of connection `id`, then reads the list again.
    /// - Returns: True when the change did not throw.
    @discardableResult
    private func run(_ id: String, _ change: @MainActor () async throws -> Void) async -> Bool {
        guard !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        notice = nil
        do {
            try await change()
        } catch {
            notice = Self.notice(for: error)
            await reload()
            return false
        }
        await reload()
        return true
    }

    private func resolveFocus() {
        guard let reference = pendingFocus else { return }
        if let found = connections.first(where: { $0.matches(reference) }) {
            focusedID = found.id
            unknownReference = nil
        } else {
            focusedID = nil
            unknownReference = reference
        }
    }

    private static func notice(for error: any Error) -> McpServersNotice {
        (error as? McpServersFailure) == .unavailable ? .unavailable : .failed
    }
}
