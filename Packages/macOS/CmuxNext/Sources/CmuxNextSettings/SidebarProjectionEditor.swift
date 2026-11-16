public import CmuxNextDesign
import Foundation

/// One edit of the sidebar's section and workspace projection settings
/// (`sidebar.sections.hidden|order`, `sidebar.workspaces.<id>`). Rust
/// (`sidebar_projection_edit`) computes the new values, so Settings, the
/// command palette and a hand edit of cmux-next.json all write the same keys.
public nonisolated enum SidebarProjectionEdit: Hashable, Sendable {
    case hideSection(String)
    case showSection(String)
    case hideWorkspace(String)
    case showWorkspace(String)
    /// Every hidden section and workspace shows again; order and groups stay.
    case showAll
    /// Every projection override goes: hides, section order, workspace groups and order.
    case reset

    var request: JSONValue {
        switch self {
        case let .hideSection(id): .object(["op": .string("hide_section"), "id": .string(id)])
        case let .showSection(id): .object(["op": .string("show_section"), "id": .string(id)])
        case let .hideWorkspace(id): .object(["op": .string("hide_workspace"), "id": .string(id)])
        case let .showWorkspace(id): .object(["op": .string("show_workspace"), "id": .string(id)])
        case .showAll: .object(["op": .string("show_all")])
        case .reset: .object(["op": .string("reset")])
        }
    }
}

/// The edit was refused (an invalid id, a full list), in Rust's words.
public struct SidebarProjectionEditRefused: Error, CustomStringConvertible {
    public let description: String
}

public nonisolated enum SidebarProjectionEditor {
    static let sectionsPath = ["sidebar", "sections"]
    static let workspacesPath = ["sidebar", "workspaces"]
    /// The flat `"sidebar.workspaces"` key the resolver also reads (it wins over the nested one).
    static let flatWorkspacesPath = ["sidebar.workspaces"]

    private struct Reply: Decodable {
        var sections: JSONValue?
        var workspaces: JSONValue?
        var changed: Bool
        var refused: String?
    }

    /// The file edits `edit` makes to `root` (cmux-next.json as written): a
    /// value sets its path, nil removes it. Empty when nothing changes.
    public static func edits(_ edit: SidebarProjectionEdit, in root: JSONValue) throws -> [(path: [String], value: JSONValue?)] {
        let flat = root[flatWorkspacesPath[0]]
        let workspacesPath = flat == nil ? workspacesPath : flatWorkspacesPath
        let request = JSONValue.object([
            "sections": root.value(at: sectionsPath) ?? .null,
            "workspaces": flat ?? root.value(at: Self.workspacesPath) ?? .null,
            "edit": edit.request,
        ])
        guard let data = try? JSONEncoder().encode(request),
              let reply: Reply = SidebarProjectionCustomizationResolver.call("sidebar_projection_edit", data) else {
            throw SidebarProjectionEditRefused(description: "the sidebar projection edit could not be planned")
        }
        if let refused = reply.refused { throw SidebarProjectionEditRefused(description: refused) }
        guard reply.changed else { return [] }
        func value(_ value: JSONValue?) -> JSONValue? {
            if case .null? = value { return nil }
            return value
        }
        return [(path: sectionsPath, value: value(reply.sections)), (path: workspacesPath, value: value(reply.workspaces))]
    }
}

extension SettingsController {
    /// Applies one projection edit to cmux-next.json in one atomic publish and
    /// waits for the reload, so the sidebar shows the result on return. True
    /// when the file changed.
    @discardableResult
    public func editSidebarProjection(_ edit: SidebarProjectionEdit) async throws -> Bool {
        let edits = try SidebarProjectionEditor.edits(edit, in: try file.document())
        guard !edits.isEmpty else { return false }
        try await file.apply(edits)
        _ = try await pruneEmpty(["sidebar"])
        await reloadAfterWrite()
        return true
    }
}
