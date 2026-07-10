package com.cmux;

import java.util.Map;

public sealed interface CmuxEvent permits TreeChangedEvent, EmptyEvent, SurfaceEvent, TitleChangedEvent, SurfaceResizedEvent, VtStateEvent, OutputEvent, ResizedEvent, UnknownEvent {
    String event();

    static CmuxEvent from(Map<String, Object> raw) {
        String event = CmuxClient.asString(raw.get("event"));
        return switch (event) {
            case "tree-changed" -> new TreeChangedEvent();
            case "empty" -> new EmptyEvent();
            case "surface-output", "surface-exited", "bell", "detached" ->
                new SurfaceEvent(event, CmuxClient.asLong(raw.get("surface")));
            case "title-changed" -> new TitleChangedEvent(
                CmuxClient.asLong(raw.get("surface")),
                raw.get("title") instanceof String title ? title : null
            );
            case "surface-resized" -> new SurfaceResizedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows"))
            );
            case "vt-state" -> new VtStateEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                CmuxClient.asString(raw.get("data"))
            );
            case "output" -> new OutputEvent(CmuxClient.asLong(raw.get("surface")), CmuxClient.asString(raw.get("data")));
            case "resized" -> new ResizedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                CmuxClient.asString(raw.get("replay"))
            );
            default -> new UnknownEvent(event, raw);
        };
    }
}
