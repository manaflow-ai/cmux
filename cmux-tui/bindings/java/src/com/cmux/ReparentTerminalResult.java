package com.cmux;

import java.util.Map;
import java.util.UUID;

public record ReparentTerminalResult(
    boolean moved,
    long workspace,
    UUID workspaceUuid,
    long screen,
    UUID screenUuid,
    long pane,
    UUID paneUuid,
    long surface,
    UUID surfaceUuid
) {
    static ReparentTerminalResult from(Map<String, Object> data) {
        Object rawMoved = data.get("moved");
        if (!(rawMoved instanceof Boolean moved)) {
            throw new IllegalArgumentException("reparent-terminal moved must be a boolean");
        }
        return new ReparentTerminalResult(
            moved,
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
