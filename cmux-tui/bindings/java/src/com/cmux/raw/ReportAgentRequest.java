// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable report-agent request. Protocol v6; authority: control. */
public final class ReportAgentRequest implements WireValue {
    private final Field<String> session;
    private final AgentReportSource source;
    private final AgentState state;
    private final UInt64 surface;

    private ReportAgentRequest(Builder builder) {
        this.session = builder.session;
        if (!builder.sourceSet) throw new IllegalArgumentException("source is required");
        this.source = Wire.nonNull(builder.source, "source");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> session() { return session; }
    public AgentReportSource source() { return source; }
    public AgentState state() { return state; }
    public UInt64 surface() { return surface; }

    public static ReportAgentRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportAgentRequest");
        Builder builder = builder();
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(rawSession == null ? null : Wire.string(rawSession, "ReportAgentRequest.session"));
        }
        Object rawSource = Wire.required(object, "source");
        builder.source(AgentReportSource.fromWire(rawSource));
        Object rawState = Wire.required(object, "state");
        builder.state(AgentState.fromWire(rawState));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReportAgentRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        Wire.put(object, "source", source);
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportAgentRequest that)) return false;
        return Objects.equals(session, that.session) && Objects.equals(source, that.source) && Objects.equals(state, that.state) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(session, source, state, surface); }

    @Override
    public String toString() { return "ReportAgentRequest" + toWire(); }

    public static final class Builder {
        private Field<String> session = Field.omitted();
        private AgentReportSource source;
        private boolean sourceSet;
        private AgentState state;
        private boolean stateSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder session(String value) {
            this.session = Field.ofNullable(value);
            return this;
        }
        public Builder source(AgentReportSource value) {
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
        public ReportAgentRequest build() { return new ReportAgentRequest(this); }
    }
}
