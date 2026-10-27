// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-host-replica-needed event. Protocol v12; streams: subscribe. */
public final class CloudHostReplicaNeededEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final Field<UInt64> expiresAt;
    private final String reason;

    private CloudHostReplicaNeededEvent(Builder builder) {
        this.cause = builder.cause;
        this.expiresAt = builder.expiresAt;
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public Field<UInt64> expiresAt() { return expiresAt; }
    public String reason() { return reason; }
    @Override public String event() { return "cloud-host-replica-needed"; }

    public static CloudHostReplicaNeededEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudHostReplicaNeededEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-host-replica-needed", "CloudHostReplicaNeededEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawExpiresAt = Wire.optional(object, "expires_at");
        if (!Wire.isMissing(rawExpiresAt)) {
            builder.expiresAt(rawExpiresAt == null ? null : Wire.uint64(rawExpiresAt, "CloudHostReplicaNeededEvent.expires_at"));
        }
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "CloudHostReplicaNeededEvent.reason"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-host-replica-needed");
        Wire.put(object, "cause", cause);
        Wire.put(object, "expires_at", expiresAt);
        Wire.put(object, "reason", reason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudHostReplicaNeededEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(expiresAt, that.expiresAt) && Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, expiresAt, reason); }

    @Override
    public String toString() { return "CloudHostReplicaNeededEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private Field<UInt64> expiresAt = Field.omitted();
        private String reason;
        private boolean reasonSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder expiresAt(UInt64 value) {
            this.expiresAt = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public CloudHostReplicaNeededEvent build() { return new CloudHostReplicaNeededEvent(this); }
    }
}
