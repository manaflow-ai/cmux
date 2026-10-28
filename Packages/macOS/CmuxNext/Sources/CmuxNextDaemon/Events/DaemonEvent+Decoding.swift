public import Foundation
public import CmuxNextWakeups

extension DaemonEvent {
    /// The `mutation_id` this event echoes, if any: workspace deltas and frontend projection
    /// changes carry the id of the mutation that caused them. Tab, pane, screen and layout deltas
    /// echo the request's `transaction` instead (``clientTransactionID``).
    public var echoedMutationID: String? {
        switch self {
        case .workspaceAdded(let d), .workspaceClosed(let d), .workspaceRenamed(let d), .workspaceMoved(let d),
             .workspaceChanged(let d): d.mutationID
        case .frontendProjectionChanged(let change): change.mutationID
        default: nil
        }
    }

    /// Who caused this event (plans/cmux-next/chrome-parity/p06-scheduler.md, "Person cause, app
    /// side"): the cause of the scope that sent the mutation or transaction it echoes when
    /// `recorded` holds that id (a person's run, the control socket's), else the envelope's `wire`
    /// cause. A missing or unknown wire cause (an old daemon) is `program`; the wire never claims
    /// `person`. A command that carries neither id (a plain `new-tab`) keeps the wire cause.
    ///
    /// - Parameters:
    ///   - wire: The envelope's `cause` field.
    ///   - recorded: The receiving connection's sent mutation ids and transactions.
    public func cause(wire: String?, recorded: MutationCauseLedger) -> ObservationCause {
        if let id = echoedMutationID, let cause = recorded.cause(of: id) { return cause }
        if let transaction = clientTransactionID, let cause = recorded.cause(ofTransaction: transaction) { return cause }
        return Self.cause(wire: wire)
    }

    /// The cause a daemon envelope names: `frontend` (a request from the verified app),
    /// `automation` (an agent, the CLI, a page), otherwise `program`.
    public static func cause(wire: String?) -> ObservationCause {
        switch wire {
        case "frontend": .frontend
        case "automation": .automation
        default: .program
        }
    }

    /// Client transaction id this event echoes, if any.
    public var clientTransactionID: ClientTransactionID? {
        switch self {
        case .workspaceAdded(let d), .workspaceClosed(let d), .workspaceRenamed(let d), .workspaceMoved(let d),
             .workspaceChanged(let d): d.clientTransactionID
        case .screenAdded(let d), .screenClosed(let d), .screenRenamed(let d), .screenChanged(let d): d.clientTransactionID
        case .paneAdded(let d), .paneClosed(let d): d.clientTransactionID
        case .tabAdded(let d), .tabClosed(let d), .tabRenamed(let d), .tabChanged(let d): d.clientTransactionID
        case .treeChanged(let transaction), .layoutChanged(_, _, let transaction): transaction
        case .conversationChanged(let event): event.transaction
        default: nil
        }
    }

    /// Decodes one subscribe-stream line whose `event` field is `name`, uncounted.
    public static func decode(name: String, line: Data) -> DaemonEvent {
        decode(name: name, line: line, decoder: uncountedDecoder)
    }

    /// ``decode(name:line:)`` with `decoder`: the connection's, which counts each decode of the line.
    /// A line costs one JSON parse: `name` picks its payload type from
    /// ``wireDecodings`` with one hash lookup, and that one parse also gives the `unknown` payload
    /// when the fields do not match. Mojo's generated stub does the same: dispatch on the message
    /// name, deserialize its params once
    /// (mojo/public/tools/bindings/generators/cpp_templates/interface_stub_declaration.tmpl).
    static func decode(name: String, line: Data, decoder: WireDecoder) -> DaemonEvent {
        guard let decoding = wireDecodings[name] else { return unmodeled(name: name, line: line, decoder: decoder) }
        return decoding.event(name, line, decoder)
    }

    /// The decoder of ``decode(name:line:)``. It counts nothing and holds no state, so one serves
    /// every call.
    private static let uncountedDecoder = WireCoding.decoder()

    /// `name` as `unknown`, with the line's JSON (`.null` when it is not JSON) as its payload.
    private static func unmodeled(name: String, line: Data, decoder: WireDecoder) -> DaemonEvent {
        .unknown(name: name, payload: (try? decoder.decode(JSONValue.self, from: line)) ?? .null)
    }

    /// How the lines of one event name become a ``DaemonEvent``.
    private struct WireDecoding: Sendable {
        let event: @Sendable (_ name: String, _ line: Data, _ decoder: WireDecoder) -> DaemonEvent
    }

    /// `make` over the line parsed once as `T`. A line whose fields do not match `T` is `unknown`
    /// with the line's JSON from that same parse.
    private static func typed<T: Decodable>(_: T.Type, _ make: @escaping @Sendable (T) -> DaemonEvent) -> WireDecoding {
        WireDecoding { name, line, decoder in
            switch try? decoder.decode(EventPayload.Typed<T>.self, from: line) {
            case .value(let value)?: return make(value)
            case .unmatched(let payload)?: return .unknown(name: name, payload: payload)
            case nil: return .unknown(name: name, payload: .null)
            }
        }
    }

    /// The event names ``wireDecodings`` models. DaemonEventSingleDecodeTests checks them against
    /// the events of cmux-tui/spec/sdk-schema.json, so the table cannot drift from the schema.
    static var modeledEventNames: Set<String> { Set(wireDecodings.keys) }

    /// Every event name the app models, with its decoding; any other name is `unknown`.
    private static let wireDecodings: [String: WireDecoding] = {
        var table: [String: WireDecoding] = [:]
        table["workspace-added"] = typed(WorkspaceDelta.self) { .workspaceAdded($0) }
        table["workspace-closed"] = typed(WorkspaceDelta.self) { .workspaceClosed($0) }
        table["workspace-renamed"] = typed(WorkspaceDelta.self) { .workspaceRenamed($0) }
        table["workspace-moved"] = typed(WorkspaceDelta.self) { .workspaceMoved($0) }
        table["workspace-changed"] = typed(WorkspaceDelta.self) { .workspaceChanged($0) }
        table["screen-added"] = typed(ScreenDelta.self) { .screenAdded($0) }
        table["screen-closed"] = typed(ScreenDelta.self) { .screenClosed($0) }
        table["screen-renamed"] = typed(ScreenDelta.self) { .screenRenamed($0) }
        table["screen-changed"] = typed(ScreenDelta.self) { .screenChanged($0) }
        table["pane-added"] = typed(PaneDelta.self) { .paneAdded($0) }
        table["pane-closed"] = typed(PaneDelta.self) { .paneClosed($0) }
        table["tab-added"] = typed(TabDelta.self) { .tabAdded($0) }
        table["tab-closed"] = typed(TabDelta.self) { .tabClosed($0) }
        table["tab-renamed"] = typed(TabDelta.self) { .tabRenamed($0) }
        table["tab-changed"] = typed(TabDelta.self) { .tabChanged($0) }
        table["tree-changed"] = typed(EventPayload.TransactionField.self) { .treeChanged(transaction: $0.clientTransactionID) }
        // Personal state (`profiles-v1`) changed: the store refetches `list-personal` alone (a group
        // fold must not refetch the tree). Its payload is never read.
        table["personal-changed"] = WireDecoding { _, _, _ in .personalChanged }
        table["layout-changed"] = typed(EventPayload.LayoutChanged.self) {
            .layoutChanged(screen: $0.screen, layout: $0.layout, transaction: $0.clientTransactionID)
        }
        table["title-changed"] = typed(EventPayload.TitleChanged.self) { .titleChanged(surface: $0.surface, title: $0.title ?? "") }
        table["surface-resized"] = typed(EventPayload.SurfaceResized.self) {
            .surfaceResized(surface: $0.surface, size: CellSize(cols: $0.cols, rows: $0.rows))
        }
        table["surface-exited"] = typed(EventPayload.SurfaceField.self) { .surfaceExited(surface: $0.surface) }
        table["scroll-changed"] = typed(EventPayload.ScrollChanged.self) {
            .scrollChanged(surface: $0.surface, offset: $0.offset, atBottom: $0.atBottom)
        }
        table["bell"] = typed(EventPayload.SurfaceField.self) { .bell(surface: $0.surface) }
        table["notification"] = typed(DaemonNotification.self) { .notification($0) }
        table["agent-changed"] = typed(AgentStatus.self) { .agentChanged($0) }
        table["agent-presence-changed"] = typed(AgentPresence.self) { .agentPresenceChanged($0) }
        table["frontend-projection-changed"] = typed(ProjectionChange.self) { .frontendProjectionChanged($0) }
        table["terminal-registry-changed"] = typed(EventPayload.TerminalRegistryChanged.self) {
            .terminalRegistryChanged(revision: $0.terminalRevision)
        }
        table["bookmarks-changed"] = typed(EventPayload.BookmarksChanged.self) {
            .bookmarksChanged(browserProfileID: $0.browserProfileID, revision: $0.revision ?? 0)
        }
        table["history-changed"] = typed(EventPayload.HistoryChanged.self) {
            .historyChanged(revision: $0.revision, kinds: $0.kinds ?? [])
        }
        table["keybindings-changed"] = typed(EventPayload.KeybindingsChanged.self) { .keybindingsChanged(revision: $0.revision) }
        table["conversation-changed"] = typed(ConversationEvent.self) { .conversationChanged($0) }
        table["conversation-typing"] = typed(ConversationTyping.self) { .conversationTyping($0) }
        table["conversation-draft"] = typed(ConversationDraft.self) { .conversationDraft($0) }
        table["conversation-live"] = typed(ConversationLive.self) { .conversationLive($0) }
        table["conversation-run-changed"] = typed(ConversationRunChanged.self) { .conversationRunChanged($0) }
        table["terminal-clipboard-read"] = typed(TerminalClipboardRead.self) { .terminalClipboardRead($0) }
        table["terminal-clipboard-read-cancelled"] = typed(EventPayload.RequestField.self) {
            .terminalClipboardReadCancelled(requestID: $0.requestID)
        }
        table["overflow"] = typed(EventPayload.OverflowEvent.self) { .overflow($0.error ?? "overflow") }
        table["daemon-shutdown"] = WireDecoding { _, _, _ in .daemonShutdown }
        for client in ["client-attached", "client-changed", "client-detached", "client-list-invalidated"] {
            table[client] = WireDecoding { name, line, decoder in
                .client(name: name, payload: (try? decoder.decode(JSONValue.self, from: line)) ?? .null)
            }
        }
        // The request id is a random u64: JSONValue numbers are Double (53 bits), so the exact id
        // goes along as a decimal string (`request_id`) for `pairing-response` (cx-hnmbt.2).
        for pairing in ["pairing-requested", "pairing-resolved"] {
            table[pairing] = typed(EventPayload.PairingRequest.self) { .unknown(name: pairing, payload: .object($0.fields)) }
        }
        // Side events that stay `unknown`, their exact u64 values carried as decimal text.
        table["apps-agent-inventory-demand"] = WireDecoding { name, line, decoder in
            .unknown(name: name, payload: AgentInventoryProviderDemand.payload(line: line, decoder: decoder))
        }
        for inventory in ["agent-inventory-changed", "agent-inventory-watch-ended"] {
            table[inventory] = WireDecoding { name, line, decoder in
                .unknown(name: name, payload: AgentInventoryWatchEvent.decode(name: name, line: line, decoder: decoder)?.payload ?? .null)
            }
        }
        table["cloud-conversation-changed"] = typed(CloudConversationChanged.self) { .cloudConversations(.changed($0)) }
        table["cloud-conversation-resynced"] = typed(CloudConversationResynced.self) { .cloudConversations(.resynced($0)) }
        table["cloud-inbox-changed"] = typed(CloudInboxChanged.self) { .cloudConversations(.inboxChanged($0)) }
        table["cloud-inbox-reset"] = typed(CloudConversationsEvent.InboxReset.self) {
            .cloudConversations(.inboxReset(seq: $0.seq ?? 0, account: $0.account))
        }
        table["cloud-subscription-state"] = typed(CloudSubscriptionState.self) { .cloudConversations(.subscriptionState($0)) }
        table["cloud-session-needed"] = typed(CloudSessionNeeded.self) { .cloudConversations(.sessionNeeded($0)) }
        table["cloud-conversation-live"] = typed(ConversationLive.self) { .cloudConversations(.live($0)) }
        table["cloud-conversation-run-changed"] = typed(ConversationRunChanged.self) { .cloudConversations(.runChanged($0)) }
        table["cloud-host-replica-needed"] = typed(CloudHostReplicaNeeded.self) { .cloudConversations(.hostReplicaNeeded($0)) }
        table["cloud-conversation-typing"] = typed(CloudConversationTyping.self) { .cloudConversations(.typing($0)) }
        table[LineTransport.streamEvent] = WireDecoding { name, line, decoder in
            guard let item = SessionStreamItem.decode(line, decoder: decoder) else { return .unknown(name: name, payload: .null) }
            return .sessionState(item)
        }
        return table
    }()
}

/// Minimal payload shapes for events whose fields map onto enum cases.
private enum EventPayload {
    /// A line parsed once as `T`, or as its JSON when its fields do not match `T` (the `unknown`
    /// event's payload), from the same parse.
    enum Typed<T: Decodable>: Decodable {
        case value(T)
        case unmatched(JSONValue)

        init(from decoder: any Decoder) throws {
            do {
                self = .value(try T(from: decoder))
            } catch {
                self = .unmatched(try JSONValue(from: decoder))
            }
        }
    }

    struct HistoryChanged: Decodable {
        var revision: UInt64
        var kinds: [String]?
    }

    /// A pairing event's fields, its exact u64 `request` added as the decimal `request_id`.
    struct PairingRequest: Decodable {
        var fields: [String: JSONValue]
        enum CodingKeys: String, CodingKey { case request }
        init(from decoder: any Decoder) throws {
            let request = try decoder.container(keyedBy: CodingKeys.self).decode(UInt64.self, forKey: .request)
            fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
            fields["request_id"] = .string(String(request))
        }
    }

    struct KeybindingsChanged: Decodable {
        var revision: UInt64
    }

    struct BookmarksChanged: Decodable {
        var browserProfileID: String
        var revision: UInt64?
        enum CodingKeys: String, CodingKey {
            case browserProfileID = "browser_profile_id"
            case revision = "bookmarks_revision"
        }
    }

    /// `layout-changed`: the screen, the echoed transaction and, with `layout-delta-v1`, the
    /// screen's layout fields, flat beside them. A layout that does not decode refetches, like none.
    struct LayoutChanged: Decodable {
        var screen: ScreenID
        var clientTransactionID: ClientTransactionID?
        var layout: ScreenLayoutDelta?
        enum CodingKeys: String, CodingKey {
            case screen, layout
            case clientTransactionID = "transaction"
        }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            screen = try c.decode(ScreenID.self, forKey: .screen)
            clientTransactionID = try c.decodeIfPresent(ClientTransactionID.self, forKey: .clientTransactionID)
            layout = c.contains(.layout) ? try? ScreenLayoutDelta(from: decoder) : nil
        }
    }

    struct TransactionField: Decodable {
        var clientTransactionID: ClientTransactionID?
        enum CodingKeys: String, CodingKey { case clientTransactionID = "transaction" }
    }

    struct SurfaceField: Decodable { var surface: SurfaceID }

    struct RequestField: Decodable {
        var requestID: String
        enum CodingKeys: String, CodingKey { case requestID = "request_id" }
    }

    struct TitleChanged: Decodable {
        var surface: SurfaceID
        var title: String?
    }

    struct SurfaceResized: Decodable {
        var surface: SurfaceID
        var cols: Int
        var rows: Int
    }

    struct ScrollChanged: Decodable {
        var surface: SurfaceID
        var offset: UInt64
        var atBottom: Bool
        enum CodingKeys: String, CodingKey {
            case surface, offset
            case atBottom = "at_bottom"
        }
    }

    struct TerminalRegistryChanged: Decodable {
        var terminalRevision: UInt64
        enum CodingKeys: String, CodingKey { case terminalRevision = "terminal_revision" }
    }

    struct OverflowEvent: Decodable { var error: String? }
}
