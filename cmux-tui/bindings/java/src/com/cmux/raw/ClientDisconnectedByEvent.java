// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable client-disconnected-by event. Protocol v12; streams: control. */
public final class ClientDisconnectedByEvent implements WireValue, ProtocolEvent {
    private final Field<SizeDetachActor> by;

    private ClientDisconnectedByEvent(Builder builder) {
        this.by = builder.by;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizeDetachActor> by() { return by; }
    @Override public String event() { return "client-disconnected-by"; }

    public static ClientDisconnectedByEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientDisconnectedByEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "client-disconnected-by", "ClientDisconnectedByEvent.event");
        Object rawBy = Wire.optional(object, "by");
        if (!Wire.isMissing(rawBy)) {
            builder.by(SizeDetachActor.fromWire(rawBy));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "client-disconnected-by");
        Wire.put(object, "by", by);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientDisconnectedByEvent that)) return false;
        return Objects.equals(by, that.by);
    }

    @Override
    public int hashCode() { return Objects.hash(by); }

    @Override
    public String toString() { return "ClientDisconnectedByEvent" + toWire(); }

    public static final class Builder {
        private Field<SizeDetachActor> by = Field.omitted();

        public Builder by(SizeDetachActor value) {
            this.by = Field.of(value);
            return this;
        }
        public ClientDisconnectedByEvent build() { return new ClientDisconnectedByEvent(this); }
    }
}
