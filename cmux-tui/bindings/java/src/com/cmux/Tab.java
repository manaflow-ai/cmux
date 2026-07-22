package com.cmux;

import java.util.Map;

public record Tab(long surface, String kind, String browserSource, String name, String title, Size size, boolean dead) {
    @SuppressWarnings("unchecked")
    static Tab from(Map<String, Object> data) {
        Size size = data.get("size") instanceof Map<?, ?> rawSize
            ? Size.from((Map<String, Object>) rawSize)
            : null;
        return new Tab(
            CmuxClient.asLong(data.get("surface")),
            CmuxClient.asString(data.get("kind")),
            data.get("browser_source") == null ? null : CmuxClient.asString(data.get("browser_source")),
            data.get("name") == null ? null : CmuxClient.asString(data.get("name")),
            CmuxClient.asString(data.get("title")),
            size,
            Boolean.TRUE.equals(data.get("dead"))
        );
    }
}
