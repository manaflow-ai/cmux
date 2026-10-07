// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-session-needed event. Protocol v12; streams: subscribe. */
public final class CloudSessionNeededEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<UInt64> expiresAt;
    private final String reason;

    private CloudSessionNeededEvent(Builder builder) {
        this.expiresAt = builder.expiresAt;
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> expiresAt() { return expiresAt; }
    public String reason() { return reason; }
    @Override public String event() { return "cloud-session-needed"; }

    public static CloudSessionNeededEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSessionNeededEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-session-needed", "CloudSessionNeededEvent.event");
        Object rawExpiresAt = Wire.optional(object, "expires_at");
        if (!Wire.isMissing(rawExpiresAt)) {
            builder.expiresAt(rawExpiresAt == null ? null : Wire.uint64(rawExpiresAt, "CloudSessionNeededEvent.expires_at"));
        }
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "CloudSessionNeededEvent.reason"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-session-needed");
        Wire.put(object, "expires_at", expiresAt);
        Wire.put(object, "reason", reason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSessionNeededEvent that)) return false;
        return Objects.equals(expiresAt, that.expiresAt) && Objects.equals(reason, that.reason);
    }

    @Override
    public int hashCode() { return Objects.hash(expiresAt, reason); }

    @Override
    public String toString() { return "CloudSessionNeededEvent" + toWire(); }

    public static final class Builder {
        private Field<UInt64> expiresAt = Field.omitted();
        private String reason;
        private boolean reasonSet;

        public Builder expiresAt(UInt64 value) {
            this.expiresAt = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public CloudSessionNeededEvent build() { return new CloudSessionNeededEvent(this); }
    }
}
