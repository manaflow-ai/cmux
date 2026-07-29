package com.cmux;

import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Render snapshot, patch, scroll, or preserved future terminal attachment item. */
public record TerminalAttachmentItem(
    String kind,
    Optional<Ids.TerminalId> terminalId,
    Map<String, Object> render,
    Map<String, Object> scroll,
    Map<String, Object> raw
) {
    public TerminalAttachmentItem {
        Objects.requireNonNull(kind, "kind");
        terminalId = terminalId == null ? Optional.empty() : terminalId;
        render = render == null ? Map.of() : Map.copyOf(render);
        scroll = scroll == null ? Map.of() : Map.copyOf(scroll);
        raw = raw == null ? Map.of() : Map.copyOf(raw);
    }
}
