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
    /// `unreadTotal`, and `clock`.
    public func dataContext(for snapshot: CustomSidebarContextSnapshot) -> [String: SwiftValue] {
        let workspaces: [SwiftValue] = snapshot.workspaces.map(workspaceValue(_:))
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
            "groups": .array(snapshot.groups.map(groupValue(_:))),
            "workspaceCount": .int(snapshot.workspaces.count),
            "selectedTitle": .string(snapshot.selectedWorkspaceTitle),
            "selectedId": .string(snapshot.selectedWorkspaceId?.uuidString ?? ""),
            "unreadTotal": .int(snapshot.totalUnreadCount),
            "clock": clock,
        ]
    }

    /// Projects one group's snapshot into the interpreter value tree.
    public func groupValue(_ group: CustomSidebarGroupSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(group.id.uuidString),
            "name": .string(group.name),
            "collapsed": .bool(group.isCollapsed),
            "pinned": .bool(group.isPinned),
            "anchorId": .string(group.anchorWorkspaceId.uuidString),
        ]
        if let color = group.customColor, !color.isEmpty {
            fields["color"] = .string(color)
        }
        if let icon = group.iconSymbol, !icon.isEmpty {
            fields["icon"] = .string(icon)
        }
        return .object(fields)
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
        if let groupId = workspace.groupId {
            fields["group"] = .string(groupId.uuidString)
        }
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
        if !workspace.agents.isEmpty {
            fields["agents"] = .array(workspace.agents.map(agentValue(_:)))
        }
        return .object(fields)
    }

    /// Projects one agent-session snapshot into the interpreter value tree
    /// (`workspaces[i].agents[j]`). Optional fields are omitted when absent.
    public func agentValue(_ agent: CustomSidebarAgentSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(agent.sessionId),
            "kind": .string(agent.kind),
            "name": .string(agent.name),
            "status": .string(agent.status),
            "lastActivityAt": .int(Int(agent.lastActivityAt.timeIntervalSince1970)),
        ]
        if let since = agent.stateSince {
            fields["sinceEpoch"] = .int(Int(since.timeIntervalSince1970))
        }
        if let title = agent.title, !title.isEmpty {
            fields["title"] = .string(title)
        }
        if let panelId = agent.panelId {
            fields["panelId"] = .string(panelId.uuidString)
        }
        if let surfaceId = agent.surfaceId {
            // The id surface.* verbs accept (surface.focus etc.); panelId
            // above is the panel behind the tab.
            fields["surfaceId"] = .string(surfaceId.uuidString)
        }
        if let directory = agent.workingDirectory, !directory.isEmpty {
            fields["directory"] = .string(directory)
        }
        if !agent.children.isEmpty {
            fields["children"] = .array(agent.children.map(agentChildValue(_:)))
        }
        if let transcriptPath = agent.transcriptPath, !transcriptPath.isEmpty {
            fields["transcriptPath"] = .string(transcriptPath)
        }
        if let pid = agent.pid {
            fields["pid"] = .int(pid)
        }
        return .object(fields)
    }

    /// Projects one child agent run into the interpreter value tree
    /// (`agents[j].children[k]`). Optional fields are omitted when absent.
    public func agentChildValue(_ child: CustomSidebarAgentChildSnapshot) -> SwiftValue {
        var fields: [String: SwiftValue] = [
            "id": .string(child.id),
            "running": .bool(child.isRunning),
            "startedEpoch": .int(Int(child.startedAt.timeIntervalSince1970)),
        ]
        if let label = child.label, !label.isEmpty {
            fields["label"] = .string(label)
        }
        if let endedAt = child.endedAt {
            fields["endedEpoch"] = .int(Int(endedAt.timeIntervalSince1970))
        }
        return .object(fields)
    }

    /// Projects one surface snapshot into the interpreter value tree, enriched
    /// with per-surface directory, pin, git, and ports where available.
    public func surfaceValue(_ surface: CustomSidebarSurfaceSnapshot) -> SwiftValue {
        var surfaceFields: [String: SwiftValue] = [
            "id": .string(surface.panelId.uuidString),
            "title": .string(surface.title),
            "focused": .bool(surface.isFocused),
            "pinned": .bool(surface.isPinned),
        ]
        if let surfaceId = surface.surfaceId {
            // The id surface.* verbs accept (surface.focus etc.); `id` above
            // is the panel behind the tab.
            surfaceFields["surfaceId"] = .string(surfaceId.uuidString)
        }
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
}
