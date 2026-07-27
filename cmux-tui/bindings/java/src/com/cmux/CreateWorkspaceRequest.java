package com.cmux;

import java.util.LinkedHashMap;
import java.util.Map;

public final class CreateWorkspaceRequest {
    private final String name;
    private final String key;
    private final Long expectedRevision;

    private CreateWorkspaceRequest(Builder builder) {
        this.name = builder.name;
        this.key = builder.key;
        this.expectedRevision = builder.expectedRevision;
    }

    public static Builder builder() {
        return new Builder();
    }

    Map<String, Object> toMap() {
        Map<String, Object> params = new LinkedHashMap<>();
        if (name != null) params.put("name", name);
        if (key != null) params.put("key", key);
        if (expectedRevision != null) params.put("expected_revision", expectedRevision);
        return params;
    }

    public static final class Builder {
        private String name;
        private String key;
        private Long expectedRevision;

        public Builder name(String name) { this.name = name; return this; }
        public Builder key(String key) { this.key = key; return this; }
        public Builder expectedRevision(long expectedRevision) {
            this.expectedRevision = expectedRevision;
            return this;
        }

        public CreateWorkspaceRequest build() {
            return new CreateWorkspaceRequest(this);
        }
    }
}
