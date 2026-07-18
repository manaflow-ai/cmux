package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public record CreateWorkspaceRequest(String name, String key, Long expectedRevision) {
    Map<String, Object> toMap() {
        Map<String, Object> params = new LinkedHashMap<>();
        if (name != null) params.put("name", name);
        if (key != null) params.put("key", key);
        if (expectedRevision != null) params.put("expected_revision", expectedRevision);
        return params;
    }
}
