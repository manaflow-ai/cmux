import Foundation

// Screen metadata (pin, color, icon), order, and screen groups: the
// daemon's `cmux.protocol/2` state resources (`screen.update`,
// `screen.move`, `screen_group.*`, cmux-tui/spec/resource-api-v2.md).
// Screens are named by public id (`screen_…`, `ScreenModel.resourceID`).
// Each change emits `tree-changed`; the snapshot it triggers reads the new
// state (`ScreenStateSnapshot`).
extension DaemonConnection {
    /// The new screen's surface and handle.
    public struct NewScreenResult: Sendable, Equatable {
        public var surface: SurfaceID
        public var screen: ScreenID?
    }

    private struct GroupValue: Decodable, Sendable {
        var id: ScreenGroupID
    }

    /// One mutation with a fresh idempotency key; the result is ignored.
    private func screenMutation(_ operation: String, _ params: [String: JSONValue]) async throws {
        _ = try await screenMutation(operation, params, as: JSONValue.self)
    }

    private func screenMutation<V: Decodable & Sendable>(_ operation: String, _ params: [String: JSONValue],
                                                           as type: V.Type) async throws -> V {
        let key = "cmux-next-screen-" + UUID().uuidString.lowercased()
        return try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<V>.self).value
    }

    static func screenUpdateParams(_ screen: ResourceID, pinned: Bool?, color: FieldUpdate<String>,
                                   icon: FieldUpdate<String>) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["screen": .string(screen.rawValue)]
        if let pinned { params["pinned"] = .bool(pinned) }
        for (name, update) in [("color", color), ("icon", icon)] {
            switch update {
            case .unchanged: break
            case .clear: params[name] = .null
            case .set(let value): params[name] = .string(value)
            }
        }
        return params
    }

    /// Pin, color, and icon; `nil`/`.unchanged` keeps a field.
    public func updateScreen(_ screen: ResourceID, pinned: Bool? = nil, color: FieldUpdate<String> = .unchanged,
                             icon: FieldUpdate<String> = .unchanged) async throws {
        try await screenMutation("screen.update", Self.screenUpdateParams(screen, pinned: pinned, color: color, icon: icon))
    }

    /// Moves `screen` to `index` in its workspace. The daemon keeps pinned
    /// screens first and each group contiguous.
    public func moveScreen(_ screen: ResourceID, to index: Int) async throws {
        try await screenMutation("screen.move", ["screen": .string(screen.rawValue), "index": .number(Double(max(0, index)))])
    }

    @discardableResult
    public func createScreenGroup(_ screens: [ResourceID], name: String? = nil, color: String? = nil) async throws -> ScreenGroupID {
        var params: [String: JSONValue] = ["screens": .array(screens.map { .string($0.rawValue) })]
        if let name { params["name"] = .string(name) }
        if let color { params["color"] = .string(color) }
        return try await screenMutation("screen_group.create", params, as: GroupValue.self).id
    }

    public func updateScreenGroup(_ group: ScreenGroupID, name: String? = nil, color: String? = nil,
                                  collapsed: Bool? = nil) async throws {
        var params: [String: JSONValue] = ["screen_group": .string(group.rawValue)]
        if let name { params["name"] = .string(name) }
        if let color { params["color"] = .string(color) }
        if let collapsed { params["collapsed"] = .bool(collapsed) }
        try await screenMutation("screen_group.update", params)
    }

    /// Adds screens after the group's last member.
    public func addScreens(_ screens: [ResourceID], toGroup group: ScreenGroupID) async throws {
        try await screenMutation("screen_group.add_screens", ["screen_group": .string(group.rawValue),
                                                              "screens": .array(screens.map { .string($0.rawValue) })])
    }

    public func removeScreensFromGroup(_ screens: [ResourceID]) async throws {
        try await screenMutation("screen_group.remove_screens", ["screens": .array(screens.map { .string($0.rawValue) })])
    }

    public func ungroupScreenGroup(_ group: ScreenGroupID) async throws {
        try await screenMutation("screen_group.ungroup", ["screen_group": .string(group.rawValue)])
    }

    /// The screen state the raw tree lacks; empty on a daemon without the
    /// protocol/2 state resources.
    func screenState() async -> ScreenStateSnapshot {
        do {
            let screens = try await resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "screen.list", params: [:], idempotencyKey: nil)
            }, as: [ScreenStateSnapshot.Screen].self)
            let groups = try await resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "screen_group.list", params: [:], idempotencyKey: nil)
            }, as: [ScreenStateSnapshot.Group].self)
            return ScreenStateSnapshot(screens: screens, groups: groups)
        } catch {
            return ScreenStateSnapshot()
        }
    }

    /// New screen in `workspace`, then `spec`: the name through `rename-screen`,
    /// the rest as state changes on the new screen's public id.
    @discardableResult
    public func newScreen(in workspace: WorkspaceHandle?, spec: ScreenSpec) async throws -> NewScreenResult {
        let created = try await newScreen(in: workspace)
        guard !spec.isEmpty else { return NewScreenResult(surface: created.surface, screen: nil) }
        let tree = try await request(ListWorkspacesRequest())
        let screen = tree.workspaces.flatMap(\.screens).first { screen in
            screen.panes.contains { $0.tabs.contains { $0.surface == created.surface } }
        }
        guard let screen else { return NewScreenResult(surface: created.surface, screen: nil) }
        if let name = spec.name { try await renameScreen(screen.id, to: name) }
        guard let id = screen.resourceID else { return NewScreenResult(surface: created.surface, screen: screen.id) }
        if spec.pinned != nil || spec.color != nil || spec.icon != nil {
            try await updateScreen(id, pinned: spec.pinned, color: spec.color.map(FieldUpdate.set) ?? .unchanged,
                                   icon: spec.icon.map(FieldUpdate.set) ?? .unchanged)
        }
        if let group = spec.group {
            try await addScreens([id], toGroup: group)
        } else if let index = spec.index {
            try await moveScreen(id, to: index)
        }
        return NewScreenResult(surface: created.surface, screen: screen.id)
    }
}
