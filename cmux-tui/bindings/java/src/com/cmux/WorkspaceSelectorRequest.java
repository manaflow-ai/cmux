package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public record WorkspaceSelectorRequest(Long workspace, String key, Long expectedRevision) {
    Map<String, Object> toMap() {
        Map<String, Object> params = new LinkedHashMap<>();
        if (workspace != null) params.put("workspace", workspace);
        if (key != null) params.put("key", key);
        if (expectedRevision != null) params.put("expected_revision", expectedRevision);
        return params;
    }
}
