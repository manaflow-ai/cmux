package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public final class WorkspaceSelectorRequest {
    private final Long workspace;
    private final String key;
    private final Long expectedRevision;

    private WorkspaceSelectorRequest(Builder builder) {
        this.workspace = builder.workspace;
        this.key = builder.key;
        this.expectedRevision = builder.expectedRevision;
    }

    public static Builder builder() {
        return new Builder();
    }

    static void requireWorkspaceOrKey(Long workspace, String key) {
        if (workspace == null && (key == null || key.isBlank())) {
            throw new IllegalArgumentException("workspace or key is required");
        }
        if (key != null && key.isBlank()) {
            throw new IllegalArgumentException("workspace key cannot be empty");
        }
    }

    Map<String, Object> toMap() {
        Map<String, Object> params = new LinkedHashMap<>();
        if (workspace != null) params.put("workspace", workspace);
        if (key != null) params.put("key", key);
        if (expectedRevision != null) params.put("expected_revision", expectedRevision);
        return params;
    }

    public static final class Builder {
        private Long workspace;
        private String key;
        private Long expectedRevision;

        public Builder workspace(long workspace) { this.workspace = workspace; return this; }
        public Builder key(String key) { this.key = key; return this; }
        public Builder expectedRevision(long expectedRevision) {
            this.expectedRevision = expectedRevision;
            return this;
        }

        public WorkspaceSelectorRequest build() {
            requireWorkspaceOrKey(workspace, key);
            return new WorkspaceSelectorRequest(this);
        }
    }
}
