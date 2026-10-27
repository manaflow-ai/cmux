// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable access-request request. Protocol v12; authority: local-admin. */
public final class AccessRequestRequest implements WireValue {
    private final String kind;
    private final Field<String> name;
    private final Field<String> path;
    private final Field<String> reason;
    private final Field<String> session;

    private AccessRequestRequest(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.name = builder.name;
        this.path = builder.path;
        this.reason = builder.reason;
        this.session = builder.session;
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return kind; }
    public Field<String> name() { return name; }
    public Field<String> path() { return path; }
    public Field<String> reason() { return reason; }
    public Field<String> session() { return session; }

    public static AccessRequestRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AccessRequestRequest");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "AccessRequestRequest.kind"));
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "AccessRequestRequest.name"));
        }
        Object rawPath = Wire.optional(object, "path");
        if (!Wire.isMissing(rawPath)) {
            builder.path(rawPath == null ? null : Wire.string(rawPath, "AccessRequestRequest.path"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "AccessRequestRequest.reason"));
        }
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(rawSession == null ? null : Wire.string(rawSession, "AccessRequestRequest.session"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "path", path);
        Wire.put(object, "reason", reason);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AccessRequestRequest that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(path, that.path) && Objects.equals(reason, that.reason) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, name, path, reason, session); }

    @Override
    public String toString() { return "AccessRequestRequest" + toWire(); }

    public static final class Builder {
        private String kind;
        private boolean kindSet;
        private Field<String> name = Field.omitted();
        private Field<String> path = Field.omitted();
        private Field<String> reason = Field.omitted();
        private Field<String> session = Field.omitted();

        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder path(String value) {
            this.path = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder session(String value) {
            this.session = Field.ofNullable(value);
            return this;
        }
        public AccessRequestRequest build() { return new AccessRequestRequest(this); }
    }
}
