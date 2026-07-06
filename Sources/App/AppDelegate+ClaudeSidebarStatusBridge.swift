import CmuxControlSocket

extension AppDelegate {
    func wireClaudeSidebarStatusBridge() {
        claudeSidebarStatusBridge = ClaudeSidebarStatusBridge(
            registry: agentChatTranscriptService.registry,
            upsert: { target, entry in
                TerminalController.shared.controlSidebarScheduleStatusUpsert(
                    target: target,
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    url: entry.url,
                    priority: entry.priority,
                    format: ControlSidebarMetadataFormat(rawValue: entry.format.rawValue) ?? .plain,
                    panelID: nil,
                    pid: nil
                )
            },
            clear: { target, key in
                TerminalController.shared.controlSidebarScheduleStatusClear(target: target, key: key)
            }
        )
    }
}
