package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Screen(long id, String name, boolean active, long activePane, Map<String, Object> layout, List<Pane> panes) {
    @SuppressWarnings("unchecked")
    static Screen from(Map<String, Object> data) {
        List<Pane> panes = new ArrayList<>();
        Object raw = data.get("panes");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                panes.add(Pane.from((Map<String, Object>) item));
            }
        }
        Map<String, Object> layout = data.get("layout") instanceof Map<?, ?> rawLayout
            ? (Map<String, Object>) rawLayout
            : Map.of();
        return new Screen(
            CmuxClient.asLong(data.get("id")),
            data.get("name") == null ? null : CmuxClient.asString(data.get("name")),
            Boolean.TRUE.equals(data.get("active")),
            CmuxClient.asLong(data.get("active_pane")),
            layout,
            panes
        );
    }
}
