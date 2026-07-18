extension RoutingHostRouter {
    static var closeFallbackLeftA: String { "term-close-left-a" }
    static var closeFallbackTarget: String { "term-close-target" }
    static var closeFallbackRight: String { "term-close-right" }
    static var closeFallbackLeftC: String { "term-close-left-c" }

    static func nilPaneIDCloseFallbackWorkspacePayload(
        title: String,
        closedTerminalIDs: Set<String>
    ) -> [String: Any] {
        let terminalOrder = [
            closeFallbackLeftA,
            closeFallbackTarget,
            closeFallbackRight,
            closeFallbackLeftC,
        ].filter { !closedTerminalIDs.contains($0) }
        let leftPaneOrder = [
            closeFallbackLeftA,
            closeFallbackTarget,
            closeFallbackLeftC,
        ].filter { !closedTerminalIDs.contains($0) }
        return [
            "id": workspaceID,
            "title": title,
            "current_directory": "/tmp/route",
            "is_selected": true,
            "focused_pane_id": "pane-left",
            "selected_terminal_id": closeFallbackTarget,
            "panes": [
                [
                    "id": "pane-left",
                    "spatial_index": 0,
                    "is_focused": true,
                    "terminal_ids": leftPaneOrder,
                ],
                [
                    "id": "pane-right",
                    "spatial_index": 1,
                    "is_focused": false,
                    "terminal_ids": [closeFallbackRight],
                ],
            ],
            "terminals": terminalOrder.map { terminalID in
                [
                    "id": terminalID,
                    "title": terminalID,
                    "current_directory": "/tmp/route",
                    "is_ready": true,
                    "is_focused": terminalID == closeFallbackTarget,
                    "can_close": true,
                    "requires_close_confirmation": false,
                ] as [String: Any]
            },
        ]
    }

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
