// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CloudAttachmentLinkResult implements WireValue {
    private final UInt64 expiresInMs;
    private final String path;

    private CloudAttachmentLinkResult(Builder builder) {
        if (!builder.expiresInMsSet) throw new IllegalArgumentException("expires_in_ms is required");
        this.expiresInMs = Wire.nonNull(builder.expiresInMs, "expires_in_ms");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 expiresInMs() { return expiresInMs; }
    public String path() { return path; }

    public static CloudAttachmentLinkResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudAttachmentLinkResult");
        Builder builder = builder();
        Object rawExpiresInMs = Wire.required(object, "expires_in_ms");
        builder.expiresInMs(Wire.uint64(rawExpiresInMs, "CloudAttachmentLinkResult.expires_in_ms"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "CloudAttachmentLinkResult.path"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expires_in_ms", expiresInMs);
        Wire.put(object, "path", path);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudAttachmentLinkResult that)) return false;
        return Objects.equals(expiresInMs, that.expiresInMs) && Objects.equals(path, that.path);
    }

    @Override
    public int hashCode() { return Objects.hash(expiresInMs, path); }

    @Override
    public String toString() { return "CloudAttachmentLinkResult" + toWire(); }

    public static final class Builder {
        private UInt64 expiresInMs;
        private boolean expiresInMsSet;
        private String path;
        private boolean pathSet;

        public Builder expiresInMs(UInt64 value) {
            this.expiresInMs = value;
            this.expiresInMsSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public CloudAttachmentLinkResult build() { return new CloudAttachmentLinkResult(this); }
    }
}
