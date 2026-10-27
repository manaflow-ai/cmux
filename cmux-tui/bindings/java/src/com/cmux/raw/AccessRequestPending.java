// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AccessRequestPending implements WireValue {
    private final UInt64 ageMs;
    private final AccessRequestKind kind;
    private final String name;
    private final String path;
    private final String reason;
    private final String requestId;
    private final String session;

    private AccessRequestPending(Builder builder) {
        if (!builder.ageMsSet) throw new IllegalArgumentException("age_ms is required");
        this.ageMs = Wire.nonNull(builder.ageMs, "age_ms");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = builder.path;
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = builder.reason;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = builder.session;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 ageMs() { return ageMs; }
    public AccessRequestKind kind() { return kind; }
    public String name() { return name; }
    public String path() { return path; }
    public String reason() { return reason; }
    public String requestId() { return requestId; }
    public String session() { return session; }

    public static AccessRequestPending fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestPending");
        Builder builder = builder();
        Object rawAgeMs = Wire.required(object, "age_ms");
        builder.ageMs(Wire.uint64(rawAgeMs, "AccessRequestPending.age_ms"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(AccessRequestKind.fromWire(rawKind));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "AccessRequestPending.name"));
        Object rawPath = Wire.required(object, "path");
        builder.path(rawPath == null ? null : Wire.string(rawPath, "AccessRequestPending.path"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(rawReason == null ? null : Wire.string(rawReason, "AccessRequestPending.reason"));
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "AccessRequestPending.request_id"));
        Object rawSession = Wire.required(object, "session");
        builder.session(rawSession == null ? null : Wire.string(rawSession, "AccessRequestPending.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "age_ms", ageMs);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "path", path);
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestPending that)) return false;
        return Objects.equals(ageMs, that.ageMs) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(path, that.path) && Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(ageMs, kind, name, path, reason, requestId, session); }

    @Override
    public String toString() { return "AccessRequestPending" + toWire(); }

    public static final class Builder {
        private UInt64 ageMs;
        private boolean ageMsSet;
        private AccessRequestKind kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private String path;
        private boolean pathSet;
        private String reason;
        private boolean reasonSet;
        private String requestId;
        private boolean requestIdSet;
        private String session;
        private boolean sessionSet;

        public Builder ageMs(UInt64 value) {
            this.ageMs = value;
            this.ageMsSet = true;
            return this;
        }
        public Builder kind(AccessRequestKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public AccessRequestPending build() { return new AccessRequestPending(this); }
    }
}
