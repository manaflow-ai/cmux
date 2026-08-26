// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentRecord implements WireValue {
    private final String session;
    private final AgentSource source;
    private final AgentState state;
    private final UInt64 surface;
    private final UInt64 updatedAtMs;

    private AgentRecord(Builder builder) {
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = builder.session;
        if (!builder.sourceSet) throw new IllegalArgumentException("source is required");
        this.source = Wire.nonNull(builder.source, "source");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.updatedAtMsSet) throw new IllegalArgumentException("updated_at_ms is required");
        this.updatedAtMs = Wire.nonNull(builder.updatedAtMs, "updated_at_ms");
    }

    public static Builder builder() { return new Builder(); }

    public String session() { return session; }
    public AgentSource source() { return source; }
    public AgentState state() { return state; }
    public UInt64 surface() { return surface; }
    public UInt64 updatedAtMs() { return updatedAtMs; }

    public static AgentRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentRecord");
        Builder builder = builder();
        Object rawSession = Wire.required(object, "session");
        builder.session(rawSession == null ? null : Wire.string(rawSession, "AgentRecord.session"));
        Object rawSource = Wire.required(object, "source");
        builder.source(AgentSource.fromWire(rawSource));
        Object rawState = Wire.required(object, "state");
        builder.state(AgentState.fromWire(rawState));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentRecord.surface"));
        Object rawUpdatedAtMs = Wire.required(object, "updated_at_ms");
        builder.updatedAtMs(Wire.uint64(rawUpdatedAtMs, "AgentRecord.updated_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        Wire.put(object, "source", source);
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        Wire.put(object, "updated_at_ms", updatedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentRecord that)) return false;
        return Objects.equals(session, that.session) && Objects.equals(source, that.source) && Objects.equals(state, that.state) && Objects.equals(surface, that.surface) && Objects.equals(updatedAtMs, that.updatedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(session, source, state, surface, updatedAtMs); }

    @Override
    public String toString() { return "AgentRecord" + toWire(); }

    public static final class Builder {
        private String session;
        private boolean sessionSet;
        private AgentSource source;
        private boolean sourceSet;
        private AgentState state;
        private boolean stateSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private UInt64 updatedAtMs;
        private boolean updatedAtMsSet;

        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder source(AgentSource value) {
            this.source = value;
            this.sourceSet = true;
            return this;
        }
        public Builder state(AgentState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder updatedAtMs(UInt64 value) {
            this.updatedAtMs = value;
            this.updatedAtMsSet = true;
            return this;
        }
        public AgentRecord build() { return new AgentRecord(this); }
    }
}
