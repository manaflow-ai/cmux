// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-dispatch request. Protocol v12; authority: local-admin. */
public final class AppsDispatchRequest implements WireValue {
    private final String event;
    private final String mountId;
    private final String node;
    private final Field<AppOrigin> origin;
    private final Field<Object> payload;

    private AppsDispatchRequest(Builder builder) {
        if (!builder.eventSet) throw new IllegalArgumentException("event is required");
        this.event = Wire.nonNull(builder.event, "event");
        if (!builder.mountIdSet) throw new IllegalArgumentException("mount_id is required");
        this.mountId = Wire.nonNull(builder.mountId, "mount_id");
        if (!builder.nodeSet) throw new IllegalArgumentException("node is required");
        this.node = Wire.nonNull(builder.node, "node");
        this.origin = builder.origin;
        this.payload = builder.payload.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public String event() { return event; }
    public String mountId() { return mountId; }
    public String node() { return node; }
    public Field<AppOrigin> origin() { return origin; }
    public Field<Object> payload() { return payload; }

    public static AppsDispatchRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsDispatchRequest");
        Builder builder = builder();
        Object rawEvent = Wire.required(object, "event");
        builder.event(Wire.string(rawEvent, "AppsDispatchRequest.event"));
        Object rawMountId = Wire.required(object, "mount_id");
        builder.mountId(Wire.string(rawMountId, "AppsDispatchRequest.mount_id"));
        Object rawNode = Wire.required(object, "node");
        builder.node(Wire.string(rawNode, "AppsDispatchRequest.node"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        Object rawPayload = Wire.optional(object, "payload");
        if (!Wire.isMissing(rawPayload)) {
            builder.payload(rawPayload == null ? null : Wire.immutableJson(rawPayload));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "event", event);
        Wire.put(object, "mount_id", mountId);
        Wire.put(object, "node", node);
        Wire.put(object, "origin", origin);
        Wire.put(object, "payload", payload);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsDispatchRequest that)) return false;
        return Objects.equals(event, that.event) && Objects.equals(mountId, that.mountId) && Objects.equals(node, that.node) && Objects.equals(origin, that.origin) && Objects.equals(payload, that.payload);
    }

    @Override
    public int hashCode() { return Objects.hash(event, mountId, node, origin, payload); }

    @Override
    public String toString() { return "AppsDispatchRequest" + toWire(); }

    public static final class Builder {
        private String event;
        private boolean eventSet;
        private String mountId;
        private boolean mountIdSet;
        private String node;
        private boolean nodeSet;
        private Field<AppOrigin> origin = Field.omitted();
        private Field<Object> payload = Field.omitted();

        public Builder event(String value) {
            this.event = value;
            this.eventSet = true;
            return this;
        }
        public Builder mountId(String value) {
            this.mountId = value;
            this.mountIdSet = true;
            return this;
        }
        public Builder node(String value) {
            this.node = value;
            this.nodeSet = true;
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public Builder payload(Object value) {
            this.payload = Field.ofNullable(value);
            return this;
        }
        public AppsDispatchRequest build() { return new AppsDispatchRequest(this); }
    }
}
