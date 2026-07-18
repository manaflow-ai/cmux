package com.cmux;

import java.util.Map;
import java.util.UUID;

public record EnsureTerminalResult(
    boolean created,
    long workspace,
    UUID workspaceUuid,
    long screen,
    UUID screenUuid,
    long pane,
    UUID paneUuid,
    long surface,
    UUID surfaceUuid
) {
    static EnsureTerminalResult from(Map<String, Object> data) {
        Object rawCreated = data.get("created");
        if (!(rawCreated instanceof Boolean created)) {
            throw new IllegalArgumentException("ensure-terminal created must be a boolean");
        }
        return new EnsureTerminalResult(
            created,
            TopologyWire.uint(data.get("workspace")),
            TopologyWire.uuid(data.get("workspace_uuid")),
            TopologyWire.uint(data.get("screen")),
            TopologyWire.uuid(data.get("screen_uuid")),
            TopologyWire.uint(data.get("pane")),
            TopologyWire.uuid(data.get("pane_uuid")),
            TopologyWire.uint(data.get("surface")),
            TopologyWire.uuid(data.get("surface_uuid"))
        );
    }
}
