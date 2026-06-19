public import CmuxSwiftRender
public import Foundation

/// Builds the interpreter data context for a custom sidebar from a
/// ``CustomSidebarContextSnapshot``.
///
/// This is the pure, value-typed projection that used to live inline in the
/// sidebar view (`customSidebarDataContext` / `customSidebarWorkspaceValue` /
/// `customSidebarSurfaceValues`). It owns the exact field set, default values,
/// and optional-field omission rules of the interpreter data keys documented
/// in `docs/custom-sidebars.md`; the app feeds it value snapshots projected
/// from live workspace state and renders the resulting `SwiftValue` tree. The
/// builder performs no I/O and reads no live objects, so its output is a pure
/// function of the snapshot plus the injected calendar.
public struct CustomSidebarDataContextBuilder {
    private let calendar: Calendar

    /// Creates a builder.
    ///
    /// - Parameter calendar: the calendar used to derive the `clock` object's
    ///   hour/minute/second/weekday components. Defaults to `Calendar.current`,
    ///   matching the original inline projection.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Projects the snapshot into the top-level interpreter data dictionary.
    ///
    /// Mirrors the original `customSidebarDataContext(now:)` output exactly:
    /// `workspaces`, `workspaceCount`, `selectedTitle`, `selectedId`,
    /// `unreadTotal`, `recents`, `recentCount`, and `clock`.
    public func dataContext(for snapshot: CustomSidebarContextSnapshot) -> [String: SwiftValue] {
        let workspaces: [SwiftValue] = snapshot.workspaces.map(workspaceValue(_:))
        let recents: [SwiftValue] = snapshot.recentFocus.map(recentFocusValue(_:))
        let components = calendar.dateComponents(
            [.hour, .minute, .second, .weekday],
            from: snapshot.now
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let clock: SwiftValue = .object([
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(components.weekday ?? 0),
            "epoch": .int(Int(snapshot.now.timeIntervalSince1970)),
        ])
        return [
            "workspaces": .array(workspaces),
            "workspaceCount": .int(snapshot.workspaces.count),
            "selectedTitle": .string(snapshot.selectedWorkspaceTitle),
            "selectedId": .string(snapshot.selectedWorkspaceId?.uuidString ?? ""),
            "unreadTotal": .int(snapshot.totalUnreadCount),
            "recents": .array(recents),
            "recentCount": .int(snapshot.recentFocus.count),
            "clock": clock,
        ]
    }

    /// Projects one workspace's snapshot into the interpreter value tree.
    ///
    /// Optional fields are omitted when absent so interpreted `if let` /
    /// ternary truthiness behaves; always-present fields default sensibly.
    public func workspaceValue(_ workspace: CustomSidebarWorkspaceSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(workspace.id.uuidString),
            "title": .string(workspace.title),
            "selected": .bool(workspace.isSelected),
            "pinned": .bool(workspace.isPinned),
            "index": .int(workspace.index),
            "directory": .string(workspace.directory),
            "ports": .array(workspace.listeningPorts.map { .int($0) }),
            "portCount": .int(workspace.listeningPorts.count),
            "unread": .int(workspace.unreadCount),
            "tabs": .array(workspace.surfaces.map(surfaceValue(_:))),
            "tabCount": .int(workspace.surfaceCount),
        ]
        if let description = workspace.customDescription, !description.isEmpty {
            fields["description"] = .string(description)
        }
        if let color = workspace.customColor, !color.isEmpty {
            fields["color"] = .string(color)
        }
        if let branch = workspace.gitBranch {
            fields["branch"] = .string(branch)
            fields["dirty"] = .bool(workspace.gitIsDirty)
        }
        if let firstPullRequest = workspace.pullRequestValues.first {
            fields["pr"] = firstPullRequest
            fields["prs"] = .array(workspace.pullRequestValues)
        }
        if let progress = workspace.progress {
            var progressFields: [String: SwiftValue] = ["value": .double(progress.value)]
            if let label = progress.label {
                progressFields["label"] = .string(label)
            }
            fields["progress"] = .object(progressFields)
        }
        if let message = workspace.latestConversationMessage, !message.isEmpty {
            fields["latestMessage"] = .string(message)
        }
        if let prompt = workspace.latestSubmittedMessage, !prompt.isEmpty {
            fields["latestPrompt"] = .string(prompt)
        }
        if let at = workspace.latestSubmittedAt {
            fields["latestAt"] = .int(Int(at.timeIntervalSince1970))
        }
        if let remote = workspace.remote {
            fields["remote"] = .object([
                "target": .string(remote.target),
                "state": .string(remote.stateRawValue),
                "connected": .bool(remote.isConnected),
            ])
        }
        return .object(fields)
    }

    /// Projects one surface snapshot into the interpreter value tree, enriched
    /// with per-surface directory, pin, git, and ports where available.
    public func surfaceValue(_ surface: CustomSidebarSurfaceSnapshot) -> SwiftValue {
        var surfaceFields: [String: SwiftValue] = [
            "id": .string(surface.panelId.uuidString),
            "title": .string(surface.title),
            "kind": .string(surface.kind),
            "focused": .bool(surface.isFocused),
            "pinned": .bool(surface.isPinned),
        ]
        if let directory = surface.directory, !directory.isEmpty {
            surfaceFields["directory"] = .string(directory)
        }
        if let branch = surface.gitBranch {
            surfaceFields["branch"] = .string(branch)
            surfaceFields["dirty"] = .bool(surface.gitIsDirty)
        }
        if !surface.listeningPorts.isEmpty {
            surfaceFields["ports"] = .array(surface.listeningPorts.map { .int($0) })
        }
        return .object(surfaceFields)
    }

    /// Projects one focus-history item into the interpreter value tree.
    public func recentFocusValue(_ recent: CustomSidebarRecentFocusSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "workspaceId": .string(recent.workspaceId.uuidString),
            "workspaceTitle": .string(recent.workspaceTitle),
            "position": .string(recent.position),
            "focusedAt": .int(Int(recent.focusedAt.timeIntervalSince1970)),
        ]
        if let panelId = recent.panelId {
            fields["panelId"] = .string(panelId.uuidString)
        }
        if let panelTitle = recent.panelTitle, !panelTitle.isEmpty {
            fields["panelTitle"] = .string(panelTitle)
        }
        return .object(fields)
    }
}
