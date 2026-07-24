package com.cmux;

import java.util.Map;

public sealed interface CmuxEvent permits TreeChangedEvent, LayoutChangedEvent, EmptyEvent, SurfaceEvent, TitleChangedEvent, SurfaceResizedEvent, SurfaceResizeFailedEvent, VtStateEvent, OutputEvent, ResizedEvent, OverflowEvent, UnknownEvent {
    String event();

    static CmuxEvent from(Map<String, Object> raw) {
        String event = CmuxClient.asString(raw.get("event"));
        return switch (event) {
            case "tree-changed" -> new TreeChangedEvent();
            case "layout-changed" -> new LayoutChangedEvent(CmuxClient.asLong(raw.get("screen")));
            case "empty" -> new EmptyEvent();
            case "overflow" -> new OverflowEvent(
                CmuxClient.asString(raw.get("error")),
                raw.get("scope") instanceof String scope ? scope : null,
                raw.get("surface") instanceof Number ? CmuxClient.asLong(raw.get("surface")) : null
            );
            case "surface-output", "surface-exited", "bell", "detached" ->
                new SurfaceEvent(event, CmuxClient.asLong(raw.get("surface")));
            case "title-changed" -> new TitleChangedEvent(
                CmuxClient.asLong(raw.get("surface")),
                raw.get("title") instanceof String title ? title : null
            );
            case "surface-resized" -> new SurfaceResizedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                raw.get("reservation_id") instanceof Number ? CmuxClient.asLong(raw.get("reservation_id")) : null
            );
            case "surface-resize-failed" -> new SurfaceResizeFailedEvent(
                CmuxClient.asLong(raw.get("surface")),
                (int) CmuxClient.asLong(raw.get("cols")),
                (int) CmuxClient.asLong(raw.get("rows")),
                CmuxClient.asString(raw.get("error")),
                raw.get("retry_after_ms") instanceof Number ? CmuxClient.asLong(raw.get("retry_after_ms")) : null,
                raw.get("reservation_id") instanceof Number ? CmuxClient.asLong(raw.get("reservation_id")) : null
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
                CmuxClient.asString(raw.containsKey("replay") ? raw.get("replay") : raw.get("data"))
            );
            default -> new UnknownEvent(event, raw);
        };
    }
}
