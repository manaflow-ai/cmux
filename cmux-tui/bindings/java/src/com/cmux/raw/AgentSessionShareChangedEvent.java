// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-share-changed event. Protocol v12; streams: subscribe. */
public final class AgentSessionShareChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String session;

    private AgentSessionShareChangedEvent(Builder builder) {
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
    }

    public static Builder builder() { return new Builder(); }

    public String session() { return session; }
    @Override public String event() { return "agent-session-share-changed"; }

    public static AgentSessionShareChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionShareChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-session-share-changed", "AgentSessionShareChangedEvent.event");
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "AgentSessionShareChangedEvent.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-session-share-changed");
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionShareChangedEvent that)) return false;
        return Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(session); }

    @Override
    public String toString() { return "AgentSessionShareChangedEvent" + toWire(); }

    public static final class Builder {
        private String session;
        private boolean sessionSet;

        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public AgentSessionShareChangedEvent build() { return new AgentSessionShareChangedEvent(this); }
    }
}
