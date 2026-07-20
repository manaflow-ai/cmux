package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Pane(long id, String name, int activeTab, long focusedAt, List<Tab> tabs, boolean dead) {
    public Pane(long id, String name, int activeTab, List<Tab> tabs, boolean dead) {
        this(id, name, activeTab, 0, tabs, dead);
    }

    @SuppressWarnings("unchecked")
    static Pane from(Map<String, Object> data) {
        List<Tab> tabs = new ArrayList<>();
        Object raw = data.get("tabs");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                tabs.add(Tab.from((Map<String, Object>) item));
            }
        }
        return new Pane(
            CmuxClient.asLong(data.get("id")),
            data.get("name") == null ? null : CmuxClient.asString(data.get("name")),
            (int) CmuxClient.asLong(data.getOrDefault("active_tab", 0)),
            CmuxClient.asLong(data.getOrDefault("focused_at", 0)),
            tabs,
            Boolean.TRUE.equals(data.get("dead"))
        );
    }
}
