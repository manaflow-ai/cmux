extension RoutingHostRouter {
    static func routingWorkspacePayload(
        title: String,
        isSelected: Bool,
        includesCreatedTerminal: Bool
    ) -> [String: Any] {
        var terminals: [[String: Any]] = [
            [
                "id": terminalA,
                "title": "A",
                "current_directory": "/tmp/route",
                "is_ready": true,
                "is_focused": !includesCreatedTerminal,
            ],
            [
                "id": terminalB,
                "title": "B",
                "current_directory": "/tmp/route",
                "is_ready": true,
                "is_focused": false,
            ],
        ]
        if includesCreatedTerminal {
            terminals.append([
                "id": "terminal-route-created",
                "title": "Created terminal",
                "current_directory": "/tmp/route",
                "is_ready": true,
                "is_focused": true,
            ])
        }
        return [
            "id": workspaceID,
            "title": title,
            "current_directory": "/tmp/route",
            "is_selected": isSelected,
            "terminals": terminals,
        ]
    }

    static func createdWorkspacePayload(isSelected: Bool) -> [String: Any] {
        [
            "id": "workspace-created",
            "title": "Created Workspace",
            "is_selected": isSelected,
            "terminals": [
                [
                    "id": "terminal-created",
                    "title": "Created",
                    "is_focused": true,
                    "is_ready": true,
                ],
            ],
        ]
    }
}
