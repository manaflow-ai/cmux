internal import Foundation

/// The `system.top` / `system.memory` workspace-node shaping: turns the typed
/// ``ControlSystemTopWorkspaceNode`` the app builds from live `Workspace` state
/// into the byte-faithful payload dictionary the legacy `v2TopWorkspaceNode`
/// produced (the worker-lane process-annotation pipeline then enriches it).
///
/// Lifted from the former `TerminalController.v2TopWorkspaceNode` /
/// `v2TopTagNodes` payload-shaping bodies; the live-state tree walk stays
/// app-side behind ``ControlSystemContext`` (it reaches `AppDelegate` /
/// `TabManager` / `Workspace` / `BrowserPanel`), and only the dictionary shaping
/// — including the tag id/ref percent-escaping — moves into the package.
extension ControlCommandCoordinator {
    /// Shapes one workspace node into the `system.top` workspace payload.
    ///
    /// Byte-faithful to the legacy `v2TopWorkspaceNode`: the `kind` markers, the
    /// minted refs, the per-pane surface sort (`indexInPane ?? index`), the
    /// browser-vs-non-browser `url` / `browser_web_content_pid` split, the
    /// single-element `webviews` array, and the tag list shape are all
    /// preserved.
    ///
    /// - Parameter node: The live-state workspace node.
    /// - Returns: The workspace payload object.
    public func systemTopWorkspacePayload(_ node: ControlSystemTopWorkspaceNode) -> JSONValue {
        .object([
            "kind": .string("workspace"),
            "id": .string(node.workspaceID.uuidString),
            "ref": ref(.workspace, node.workspaceID),
            "index": .int(Int64(node.index)),
            "title": .string(node.title),
            "description": orNull(node.description),
            "selected": .bool(node.isSelected),
            "pinned": .bool(node.isPinned),
            "panes": .array(node.panes.map(systemTopPanePayload)),
            "tags": .array(node.tags.map(systemTopTagPayload)),
        ])
    }

    /// The `system.top` pane node payload (the legacy per-pane dictionary).
    private func systemTopPanePayload(_ node: ControlSystemTopPaneNode) -> JSONValue {
        .object([
            "kind": .string("pane"),
            "id": .string(node.paneID.uuidString),
            "ref": ref(.pane, node.paneID),
            "index": .int(Int64(node.index)),
            "focused": .bool(node.isFocused),
            "surface_ids": .array(node.surfaceIDs.map { .string($0.uuidString) }),
            "surface_refs": .array(node.surfaceIDs.map { ref(.surface, $0) }),
            "selected_surface_id": orNull(node.selectedSurfaceID?.uuidString),
            "selected_surface_ref": ref(.surface, node.selectedSurfaceID),
            "surface_count": .int(Int64(node.surfaceIDs.count)),
            "surfaces": .array(node.surfaces.map(systemTopSurfacePayload)),
        ])
    }

    /// The `system.top` surface node payload (the legacy per-panel dictionary,
    /// pre-annotation). Browser surfaces emit `url` / `browser_web_content_pid` /
    /// `browser_webview_lifecycle_state` plus a one-element `webviews` array;
    /// non-browsers emit JSON `null` for `url` / `browser_web_content_pid`.
    private func systemTopSurfacePayload(_ node: ControlSystemTopSurfaceNode) -> JSONValue {
        var item: [String: JSONValue] = [
            "kind": .string("surface"),
            "id": .string(node.surfaceID.uuidString),
            "ref": ref(.surface, node.surfaceID),
            "index": .int(Int64(node.index)),
            "type": .string(node.typeRawValue),
            "title": .string(node.title),
            "focused": .bool(node.isFocused),
            "selected": .bool(node.isSelected),
            "selected_in_pane": node.selectedInPane.map { JSONValue.bool($0) } ?? .null,
            "pane_id": orNull(node.paneID?.uuidString),
            "pane_ref": ref(.pane, node.paneID),
            "index_in_pane": node.indexInPane.map { JSONValue.int(Int64($0)) } ?? .null,
            "tty": orNull(node.tty),
            "webviews": .array(node.webviews.map(systemTopWebViewPayload)),
        ]

        if node.isBrowser {
            item["url"] = .string(node.browserURL ?? "")
            item["browser_web_content_pid"] = node.browserWebContentPID.map { JSONValue.int(Int64($0)) } ?? .null
            item["browser_webview_lifecycle_state"] = .string(node.browserWebViewLifecycleStateRawValue ?? "")
        } else {
            item["url"] = .null
            item["browser_web_content_pid"] = .null
        }
        return .object(item)
    }

    /// The `system.top` webview node payload (the legacy single per-`webviews`
    /// dictionary; the id/ref are minted from the surface id as
    /// `"<surfaceID>:webview"`).
    private func systemTopWebViewPayload(_ node: ControlSystemTopWebViewNode) -> JSONValue {
        .object([
            "kind": .string("webview"),
            "id": .string("\(node.surfaceID.uuidString):webview"),
            "ref": .string("\(refString(.surface, node.surfaceID)):webview"),
            "index": .int(Int64(node.index)),
            "surface_id": .string(node.surfaceID.uuidString),
            "surface_ref": ref(.surface, node.surfaceID),
            "title": .string(node.title),
            "url": .string(node.url),
            "pid": node.pid.map { JSONValue.int(Int64($0)) } ?? .null,
            "lifecycle": node.lifecycle,
        ])
    }

    /// The `system.top` tag node payload (the legacy per-`tags` dictionary; the
    /// id/ref are minted from the workspace id and percent-escaped key).
    private func systemTopTagPayload(_ node: ControlSystemTopTagNode) -> JSONValue {
        .object([
            "kind": .string("tag"),
            "id": .string(Self.systemTopTagIdentifier(workspaceID: node.workspaceID, key: node.key)),
            "ref": .string(Self.systemTopTagRef(workspaceID: node.workspaceID, key: node.key)),
            "index": .int(Int64(node.index)),
            "key": .string(node.key),
            "value": .string(node.value),
            "icon": orNull(node.icon),
            "color": orNull(node.color),
            "url": orNull(node.url),
            "priority": .int(Int64(node.priority)),
            "format": .string(node.formatRawValue),
            "visible": .bool(node.isVisible),
            "pid": node.pid.map { JSONValue.int(Int64($0)) } ?? .null,
        ])
    }

    /// The `kind:N` ref string for a known id (the webview ref appends
    /// `":webview"` to it, so this returns the unwrapped string rather than the
    /// ``ref(_:_:)`` JSON value).
    private func refString(_ kind: ControlHandleKind, _ uuid: UUID) -> String {
        handles.ensureRef(kind: kind, uuid: uuid)
    }

    /// The legacy `v2TopTagIdentifier`: `"<workspaceID>:tag:<escapedKey>"`.
    static func systemTopTagIdentifier(workspaceID: UUID, key: String) -> String {
        "\(workspaceID.uuidString):tag:\(systemTopEscapedTagKey(key))"
    }

    /// The legacy `v2TopTagRef`: `"workspace:<workspaceID>:tag:<escapedKey>"`.
    static func systemTopTagRef(workspaceID: UUID, key: String) -> String {
        "workspace:\(workspaceID.uuidString):tag:\(systemTopEscapedTagKey(key))"
    }

    /// The legacy `v2TopEscapedTagKey`: percent-encodes the key over the
    /// alphanumerics plus `-._~` set (empty string on encode failure).
    private static func systemTopEscapedTagKey(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
