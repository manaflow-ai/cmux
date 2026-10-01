public import Foundation

extension DaemonEvent {
    /// Client transaction id this event echoes, if any.
    public var clientTransactionID: ClientTransactionID? {
        switch self {
        case .workspaceAdded(let d), .workspaceClosed(let d), .workspaceRenamed(let d), .workspaceMoved(let d),
             .workspaceChanged(let d): d.clientTransactionID
        case .screenAdded(let d), .screenClosed(let d), .screenRenamed(let d), .screenChanged(let d): d.clientTransactionID
        case .paneAdded(let d), .paneClosed(let d): d.clientTransactionID
        case .tabAdded(let d), .tabClosed(let d), .tabRenamed(let d), .tabChanged(let d): d.clientTransactionID
        case .treeChanged(let transaction), .layoutChanged(_, let transaction): transaction
        default: nil
        }
    }

    /// Decodes one subscribe-stream line whose `event` field is `name`.
    public static func decode(name: String, line: Data) -> DaemonEvent {
        let decoder = WireCoding.decoder()
        func payload() -> JSONValue { (try? decoder.decode(JSONValue.self, from: line)) ?? .null }
        func d<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(T.self, from: line) }
        do {
            switch name {
            case "workspace-added": return .workspaceAdded(try d(WorkspaceDelta.self))
            case "workspace-closed": return .workspaceClosed(try d(WorkspaceDelta.self))
            case "workspace-renamed": return .workspaceRenamed(try d(WorkspaceDelta.self))
            case "workspace-moved": return .workspaceMoved(try d(WorkspaceDelta.self))
            case "workspace-changed": return .workspaceChanged(try d(WorkspaceDelta.self))
            case "screen-added": return .screenAdded(try d(ScreenDelta.self))
            case "screen-closed": return .screenClosed(try d(ScreenDelta.self))
            case "screen-renamed": return .screenRenamed(try d(ScreenDelta.self))
            case "screen-changed": return .screenChanged(try d(ScreenDelta.self))
            case "pane-added": return .paneAdded(try d(PaneDelta.self))
            case "pane-closed": return .paneClosed(try d(PaneDelta.self))
            case "tab-added": return .tabAdded(try d(TabDelta.self))
            case "tab-closed": return .tabClosed(try d(TabDelta.self))
            case "tab-renamed": return .tabRenamed(try d(TabDelta.self))
            case "tab-changed": return .tabChanged(try d(TabDelta.self))
            case "tree-changed": return .treeChanged(transaction: try d(EventPayload.TransactionField.self).clientTransactionID)
            // Personal state (`profiles-v1`) changed: the snapshot refetches
            // `list-personal` with the tree, like saved tab groups.
            case "personal-changed": return .treeChanged(transaction: nil)
            case "layout-changed":
                let e = try d(EventPayload.ScreenField.self)
                return .layoutChanged(screen: e.screen, transaction: e.clientTransactionID)
            case "title-changed":
                let e = try d(EventPayload.TitleChanged.self)
                return .titleChanged(surface: e.surface, title: e.title ?? "")
            case "surface-resized":
                let e = try d(EventPayload.SurfaceResized.self)
                return .surfaceResized(surface: e.surface, size: CellSize(cols: e.cols, rows: e.rows))
            case "surface-exited": return .surfaceExited(surface: try d(EventPayload.SurfaceField.self).surface)
            case "scroll-changed":
                let e = try d(EventPayload.ScrollChanged.self)
                return .scrollChanged(surface: e.surface, offset: e.offset, atBottom: e.atBottom)
            case "bell": return .bell(surface: try d(EventPayload.SurfaceField.self).surface)
            case "notification": return .notification(try d(DaemonNotification.self))
            case "agent-changed": return .agentChanged(try d(AgentStatus.self))
            case "frontend-projection-changed": return .frontendProjectionChanged(try d(ProjectionChange.self))
            case "terminal-registry-changed":
                return .terminalRegistryChanged(revision: try d(EventPayload.TerminalRegistryChanged.self).terminalRevision)
            case "client-attached", "client-changed", "client-detached", "client-list-invalidated":
                return .client(name: name, payload: payload())
            case "overflow": return .overflow(try d(EventPayload.OverflowEvent.self).error ?? "overflow")
            case "daemon-shutdown": return .daemonShutdown
            // `cmux.protocol/2` stream lines (LineTransport routes them by `type`).
            case "stream_item", "stream_end":
                return try d(SessionEventsLine.self).event ?? .unknown(name: name, payload: .null)
            default: return .unknown(name: name, payload: payload())
            }
        } catch {
            return .unknown(name: name, payload: payload())
        }
    }
}

/// Minimal payload shapes for events whose fields map onto enum cases.
private enum EventPayload {
    struct ScreenField: Decodable {
        var screen: ScreenID
        var clientTransactionID: ClientTransactionID?
        enum CodingKeys: String, CodingKey {
            case screen
            case clientTransactionID = "transaction"
        }
    }

    struct TransactionField: Decodable {
        var clientTransactionID: ClientTransactionID?
        enum CodingKeys: String, CodingKey { case clientTransactionID = "transaction" }
    }

    struct SurfaceField: Decodable { var surface: SurfaceID }

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
