// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentRecord implements WireValue {
    /** Adapter identity (`claude`, `codex`, ...) when a hook claimed the terminal; null for socket-only reports. */
    private final Field<String> agent;
    /** The harness's own session id that the agent's hooks reported (`claude`, `codex` session ids), checked to `[A-Za-z0-9._:-]` and at most 256 bytes; null when no hook reported one or it isn't portable (a session-less adapter's local token). Hook reports keep `session` for a human label, so clients find a terminal's agent session by this. */
    private final Field<String> agentSessionId;
    /** The terminal agent's last prompt (at most 200 characters), kept in daemon memory only: never journaled or persisted; null when none since the agent started or the daemon restarted. */
    private final Field<String> lastPrompt;
    private final String session;
    /** When the agent entered `state` (Unix ms). A report that keeps the state keeps it; after a daemon restart it is the last report's time. Absent from older senders: use `updated_at_ms`. */
    private final Field<UInt64> sinceMs;
    private final AgentSource source;
    private final AgentState state;
    private final UInt64 surface;
    private final UInt64 updatedAtMs;

    private AgentRecord(Builder builder) {
        this.agent = builder.agent;
        this.agentSessionId = builder.agentSessionId;
        this.lastPrompt = builder.lastPrompt;
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = builder.session;
        this.sinceMs = builder.sinceMs;
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

    public Field<String> agent() { return agent; }
    public Field<String> agentSessionId() { return agentSessionId; }
    public Field<String> lastPrompt() { return lastPrompt; }
    public String session() { return session; }
    public Field<UInt64> sinceMs() { return sinceMs; }
    public AgentSource source() { return source; }
    public AgentState state() { return state; }
    public UInt64 surface() { return surface; }
    public UInt64 updatedAtMs() { return updatedAtMs; }

    public static AgentRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentRecord");
        Builder builder = builder();
        Object rawAgent = Wire.optional(object, "agent");
        if (!Wire.isMissing(rawAgent)) {
            builder.agent(rawAgent == null ? null : Wire.string(rawAgent, "AgentRecord.agent"));
        }
        Object rawAgentSessionId = Wire.optional(object, "agent_session_id");
        if (!Wire.isMissing(rawAgentSessionId)) {
            builder.agentSessionId(rawAgentSessionId == null ? null : Wire.string(rawAgentSessionId, "AgentRecord.agent_session_id"));
        }
        Object rawLastPrompt = Wire.optional(object, "last_prompt");
        if (!Wire.isMissing(rawLastPrompt)) {
            builder.lastPrompt(rawLastPrompt == null ? null : Wire.string(rawLastPrompt, "AgentRecord.last_prompt"));
        }
        Object rawSession = Wire.required(object, "session");
        builder.session(rawSession == null ? null : Wire.string(rawSession, "AgentRecord.session"));
        Object rawSinceMs = Wire.optional(object, "since_ms");
        if (!Wire.isMissing(rawSinceMs)) {
            builder.sinceMs(Wire.uint64(rawSinceMs, "AgentRecord.since_ms"));
        }
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
        Wire.put(object, "agent", agent);
        Wire.put(object, "agent_session_id", agentSessionId);
        Wire.put(object, "last_prompt", lastPrompt);
        Wire.put(object, "session", session);
        Wire.put(object, "since_ms", sinceMs);
        Wire.put(object, "source", source);
        Wire.put(object, "state", state);
        Wire.put(object, "surface", surface);
        Wire.put(object, "updated_at_ms", updatedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentRecord that)) return false;
        return Objects.equals(agent, that.agent) && Objects.equals(agentSessionId, that.agentSessionId) && Objects.equals(lastPrompt, that.lastPrompt) && Objects.equals(session, that.session) && Objects.equals(sinceMs, that.sinceMs) && Objects.equals(source, that.source) && Objects.equals(state, that.state) && Objects.equals(surface, that.surface) && Objects.equals(updatedAtMs, that.updatedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(agent, agentSessionId, lastPrompt, session, sinceMs, source, state, surface, updatedAtMs); }

    @Override
    public String toString() { return "AgentRecord" + toWire(); }

    public static final class Builder {
        private Field<String> agent = Field.omitted();
        private Field<String> agentSessionId = Field.omitted();
        private Field<String> lastPrompt = Field.omitted();
        private String session;
        private boolean sessionSet;
        private Field<UInt64> sinceMs = Field.omitted();
        private AgentSource source;
        private boolean sourceSet;
        private AgentState state;
        private boolean stateSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private UInt64 updatedAtMs;
        private boolean updatedAtMsSet;

        public Builder agent(String value) {
            this.agent = Field.ofNullable(value);
            return this;
        }
        public Builder agentSessionId(String value) {
            this.agentSessionId = Field.ofNullable(value);
            return this;
        }
        public Builder lastPrompt(String value) {
            this.lastPrompt = Field.ofNullable(value);
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder sinceMs(UInt64 value) {
            this.sinceMs = Field.of(value);
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
