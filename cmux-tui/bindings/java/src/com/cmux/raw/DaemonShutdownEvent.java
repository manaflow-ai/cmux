// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable daemon-shutdown event. Protocol v12; streams: control. */
public final class DaemonShutdownEvent implements WireValue, ProtocolEvent {
    private final Field<Boolean> restart;

    private DaemonShutdownEvent(Builder builder) {
        this.restart = builder.restart;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> restart() { return restart; }
    @Override public String event() { return "daemon-shutdown"; }

    public static DaemonShutdownEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DaemonShutdownEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "daemon-shutdown", "DaemonShutdownEvent.event");
        Object rawRestart = Wire.optional(object, "restart");
        if (!Wire.isMissing(rawRestart)) {
            builder.restart(Wire.bool(rawRestart, "DaemonShutdownEvent.restart"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "daemon-shutdown");
        Wire.put(object, "restart", restart);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DaemonShutdownEvent that)) return false;
        return Objects.equals(restart, that.restart);
    }

    @Override
    public int hashCode() { return Objects.hash(restart); }

    @Override
    public String toString() { return "DaemonShutdownEvent" + toWire(); }

    public static final class Builder {
        private Field<Boolean> restart = Field.omitted();

        public Builder restart(Boolean value) {
            this.restart = Field.of(value);
            return this;
        }
        public DaemonShutdownEvent build() { return new DaemonShutdownEvent(this); }
    }
}
