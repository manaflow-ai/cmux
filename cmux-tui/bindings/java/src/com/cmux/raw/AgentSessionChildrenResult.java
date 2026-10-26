// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionChildrenResult implements WireValue {
    /** At most 256 summaries and 8 MiB, in acpmux's order. */
    private final List<Object> sessions;

    private AgentSessionChildrenResult(Builder builder) {
        if (!builder.sessionsSet) throw new IllegalArgumentException("sessions is required");
        this.sessions = List.copyOf(Wire.nonNull(builder.sessions, "sessions"));
    }

    public static Builder builder() { return new Builder(); }

    public List<Object> sessions() { return sessions; }

    public static AgentSessionChildrenResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionChildrenResult");
        Builder builder = builder();
        Object rawSessions = Wire.required(object, "sessions");
        builder.sessions(Wire.array(rawSessions, "AgentSessionChildrenResult.sessions", item -> Wire.immutableJson(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "sessions", sessions);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionChildrenResult that)) return false;
        return Objects.equals(sessions, that.sessions);
    }

    @Override
    public int hashCode() { return Objects.hash(sessions); }

    @Override
    public String toString() { return "AgentSessionChildrenResult" + toWire(); }

    public static final class Builder {
        private List<Object> sessions;
        private boolean sessionsSet;

        public Builder sessions(List<Object> value) {
            this.sessions = value;
            this.sessionsSet = true;
            return this;
        }
        public AgentSessionChildrenResult build() { return new AgentSessionChildrenResult(this); }
    }
}
