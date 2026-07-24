import Foundation

/// Normalizes and validates host messages before JSON encoding or admission.
public struct WorkspaceShareOutboundMessageValidator: Sendable {
    /// Creates a stateless validator.
    public init() {}

    /// Returns a bounded wire-safe message, or `nil` for invalid structure.
    ///
    /// User-visible chat and titles are truncated on Unicode-scalar boundaries.
    /// Structural fields fail closed because truncating identifiers or layouts
    /// would change routing semantics.
    public func prepare(_ message: ShareHostMessage) -> ShareHostMessage? {
        switch message {
        case .hello(let shared, let layouts):
            guard let shared = prepare(shared),
                  let layouts = prepare(layouts),
                  Set(shared.map(\.id)) == Set(layouts.map(\.ws)) else {
                return nil
            }
            return .hello(shared: shared, layouts: layouts)
        case .layout(let layout):
            guard let layout = prepare(layout) else { return nil }
            return .layout(layout)
        case .shared(let shared):
            guard let shared = prepare(shared) else { return nil }
            return .shared(shared)
        case .approve(let user, let role):
            return isID(user) ? .approve(user: user, role: role) : nil
        case .deny(let user):
            return isID(user) ? .deny(user: user) : nil
        case .kick(let user):
            return isID(user) ? .kick(user: user) : nil
        case .role(let user, let role):
            return isID(user) ? .role(user: user, role: role) : nil
        case .cursor(let pos):
            guard pos.map(accepts) ?? true else { return nil }
            return .cursor(pos)
        case .chat(let text, let bubble):
            guard bubble.map(accepts) ?? true else { return nil }
            return .chat(
                text: Self.truncateUTF8(
                    text,
                    maximumBytes: ShareProtocolConstants.maximumChatTextBytes
                ),
                bubble: bubble
            )
        case .focus(let ws):
            guard ws.map(isID) ?? true else { return nil }
            return .focus(ws: ws)
        case .ack, .end:
            return message
        }
    }

    /// Returns a semantically valid message only when its encoded JSON also
    /// fits the host frame ceiling.
    public func prepareForTransport(
        _ message: ShareHostMessage
    ) -> ShareHostMessage? {
        guard let message = prepare(message),
              let data = try? JSONEncoder().encode(message),
              WorkspaceShareTextFramePolicy.acceptsHostFrame(
                  byteCount: data.count
              ) else {
            return nil
        }
        return message
    }

    /// Truncates without splitting a Unicode scalar's UTF-8 encoding.
    public static func truncateUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = scalar.utf8.count
            guard byteCount <= maximumBytes - scalarByteCount else { break }
            result.append(scalar)
            byteCount += scalarByteCount
        }
        return String(result)
    }

    private func prepare(
        _ shared: [ShareSharedWorkspace]
    ) -> [ShareSharedWorkspace]? {
        guard shared.count <= ShareProtocolConstants.maximumSharedWorkspaces,
              Set(shared.map(\.id)).count == shared.count,
              shared.allSatisfy({ isID($0.id) }) else {
            return nil
        }
        return shared.map {
            ShareSharedWorkspace(
                id: $0.id,
                title: Self.truncateUTF8(
                    $0.title,
                    maximumBytes: ShareProtocolConstants.maximumTitleBytes
                )
            )
        }
    }

    private func prepare(
        _ layouts: [ShareWorkspaceLayout]
    ) -> [ShareWorkspaceLayout]? {
        guard layouts.count <= ShareProtocolConstants.maximumSharedWorkspaces,
              Set(layouts.map(\.ws)).count == layouts.count else {
            return nil
        }
        var result: [ShareWorkspaceLayout] = []
        result.reserveCapacity(layouts.count)
        for layout in layouts {
            guard let layout = prepare(layout) else { return nil }
            result.append(layout)
        }
        return result
    }

    private func prepare(
        _ layout: ShareWorkspaceLayout
    ) -> ShareWorkspaceLayout? {
        guard isID(layout.ws) else { return nil }
        guard let tree = layout.tree else {
            return ShareWorkspaceLayout(ws: layout.ws, tree: nil)
        }
        var panes = 0
        var nodes = 0
        var paneIDs = Set<String>()
        guard let tree = prepare(
            tree,
            depth: 1,
            panes: &panes,
            nodes: &nodes,
            paneIDs: &paneIDs
        ) else {
            return nil
        }
        return ShareWorkspaceLayout(ws: layout.ws, tree: tree)
    }

    private func prepare(
        _ node: ShareLayoutNode,
        depth: Int,
        panes: inout Int,
        nodes: inout Int,
        paneIDs: inout Set<String>
    ) -> ShareLayoutNode? {
        let maximumNodes = ShareProtocolConstants.maximumLayoutPanes * 2 - 1
        guard depth <= ShareProtocolConstants.maximumLayoutDepth,
              nodes < maximumNodes else {
            return nil
        }
        nodes += 1
        switch node {
        case .split(let axis, let ratio, let a, let b):
            guard (axis == "h" || axis == "v"),
                  ratio.isFinite,
                  ratio > 0,
                  ratio < 1,
                  let a = prepare(
                      a,
                      depth: depth + 1,
                      panes: &panes,
                      nodes: &nodes,
                      paneIDs: &paneIDs
                  ),
                  let b = prepare(
                      b,
                      depth: depth + 1,
                      panes: &panes,
                      nodes: &nodes,
                      paneIDs: &paneIDs
                  ) else {
                return nil
            }
            return .split(axis: axis, ratio: ratio, a: a, b: b)
        case .pane(let pane, let content, let cols, let rows, let title):
            guard panes < ShareProtocolConstants.maximumLayoutPanes,
                  isID(pane),
                  paneIDs.insert(pane).inserted,
                  content == "terminal"
                      || content == "browser"
                      || content == "agent"
                      || content == "other",
                  cols.map({ (1...10_000).contains($0) }) ?? true,
                  rows.map({ (1...10_000).contains($0) }) ?? true else {
                return nil
            }
            panes += 1
            return .pane(
                pane: pane,
                content: content,
                cols: cols,
                rows: rows,
                title: title.map {
                    Self.truncateUTF8(
                        $0,
                        maximumBytes: ShareProtocolConstants.maximumTitleBytes
                    )
                }
            )
        }
    }

    private func accepts(_ cursor: ShareCursorPos) -> Bool {
        isID(cursor.ws)
            && isID(cursor.pane)
            && cursor.x.isFinite
            && cursor.y.isFinite
            && (0...1).contains(cursor.x)
            && (0...1).contains(cursor.y)
    }

    private func isID(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        return byteCount > 0
            && byteCount <= ShareProtocolConstants.maximumIDBytes
            && value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
    }
}
