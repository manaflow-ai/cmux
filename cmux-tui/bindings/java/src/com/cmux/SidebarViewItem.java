package com.cmux;

import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Render snapshot, patch, scroll, or preserved future sidebar attachment item. */
public record SidebarViewItem(
    String kind,
    Optional<Snapshots.SidebarViewSnapshot> sidebarView,
    Optional<Ids.SidebarViewId> sidebarViewId,
    Map<String, Object> render,
    Map<String, Object> scroll,
    Map<String, Object> raw
) {
    public SidebarViewItem {
        Objects.requireNonNull(kind, "kind");
        sidebarView = sidebarView == null ? Optional.empty() : sidebarView;
        sidebarViewId = sidebarViewId == null ? Optional.empty() : sidebarViewId;
        render = render == null ? Map.of() : Map.copyOf(render);
        scroll = scroll == null ? Map.of() : Map.copyOf(scroll);
        raw = raw == null ? Map.of() : Map.copyOf(raw);
    }
}
