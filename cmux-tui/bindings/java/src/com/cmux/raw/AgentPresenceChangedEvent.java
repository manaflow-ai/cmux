// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-presence-changed event. Protocol v12; streams: subscribe. */
public final class AgentPresenceChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What the agent is doing now; null clears the surface's presence and every other field is then null. */
    private final AgentPresenceActivity activity;
    /** Adapter identity (claude, codex, ...). */
    private final String agent;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    /** The 1-based line the tool call targets, when the tool input names one. */
    private final UInt64 line;
    /** The file the tool call targets, when the tool input names one. */
    private final String path;
    /** The agent's portable session id, a stable identity for colour. */
    private final String session;
    private final UInt64 surface;
    /** The native tool name of the current or last tool call. */
    private final String tool;
    /** When the hook observed the event; null on clear. */
    private final UInt64 updatedAtMs;

    private AgentPresenceChangedEvent(Builder builder) {
        if (!builder.activitySet) throw new IllegalArgumentException("activity is required");
        this.activity = builder.activity;
        if (!builder.agentSet) throw new IllegalArgumentException("agent is required");
        this.agent = builder.agent;
        this.cause = builder.cause;
        if (!builder.lineSet) throw new IllegalArgumentException("line is required");
        this.line = builder.line;
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = builder.path;
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = builder.session;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.toolSet) throw new IllegalArgumentException("tool is required");
        this.tool = builder.tool;
        if (!builder.updatedAtMsSet) throw new IllegalArgumentException("updated_at_ms is required");
        this.updatedAtMs = builder.updatedAtMs;
    }

    public static Builder builder() { return new Builder(); }

    public AgentPresenceActivity activity() { return activity; }
    public String agent() { return agent; }
    public Field<EventCause> cause() { return cause; }
    public UInt64 line() { return line; }
    public String path() { return path; }
    public String session() { return session; }
    public UInt64 surface() { return surface; }
    public String tool() { return tool; }
    public UInt64 updatedAtMs() { return updatedAtMs; }
    @Override public String event() { return "agent-presence-changed"; }

    public static AgentPresenceChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentPresenceChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "agent-presence-changed", "AgentPresenceChangedEvent.event");
        Object rawActivity = Wire.required(object, "activity");
        builder.activity(rawActivity == null ? null : AgentPresenceActivity.fromWire(rawActivity));
        Object rawAgent = Wire.required(object, "agent");
        builder.agent(rawAgent == null ? null : Wire.string(rawAgent, "AgentPresenceChangedEvent.agent"));
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawLine = Wire.required(object, "line");
        builder.line(rawLine == null ? null : Wire.uint64(rawLine, "AgentPresenceChangedEvent.line"));
        Object rawPath = Wire.required(object, "path");
        builder.path(rawPath == null ? null : Wire.string(rawPath, "AgentPresenceChangedEvent.path"));
        Object rawSession = Wire.required(object, "session");
        builder.session(rawSession == null ? null : Wire.string(rawSession, "AgentPresenceChangedEvent.session"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentPresenceChangedEvent.surface"));
        Object rawTool = Wire.required(object, "tool");
        builder.tool(rawTool == null ? null : Wire.string(rawTool, "AgentPresenceChangedEvent.tool"));
        Object rawUpdatedAtMs = Wire.required(object, "updated_at_ms");
        builder.updatedAtMs(rawUpdatedAtMs == null ? null : Wire.uint64(rawUpdatedAtMs, "AgentPresenceChangedEvent.updated_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "agent-presence-changed");
        Wire.put(object, "activity", activity);
        Wire.put(object, "agent", agent);
        Wire.put(object, "cause", cause);
        Wire.put(object, "line", line);
        Wire.put(object, "path", path);
        Wire.put(object, "session", session);
        Wire.put(object, "surface", surface);
        Wire.put(object, "tool", tool);
        Wire.put(object, "updated_at_ms", updatedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentPresenceChangedEvent that)) return false;
        return Objects.equals(activity, that.activity) && Objects.equals(agent, that.agent) && Objects.equals(cause, that.cause) && Objects.equals(line, that.line) && Objects.equals(path, that.path) && Objects.equals(session, that.session) && Objects.equals(surface, that.surface) && Objects.equals(tool, that.tool) && Objects.equals(updatedAtMs, that.updatedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(activity, agent, cause, line, path, session, surface, tool, updatedAtMs); }

    @Override
    public String toString() { return "AgentPresenceChangedEvent" + toWire(); }

    public static final class Builder {
        private AgentPresenceActivity activity;
        private boolean activitySet;
        private String agent;
        private boolean agentSet;
        private Field<EventCause> cause = Field.omitted();
        private UInt64 line;
        private boolean lineSet;
        private String path;
        private boolean pathSet;
        private String session;
        private boolean sessionSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String tool;
        private boolean toolSet;
        private UInt64 updatedAtMs;
        private boolean updatedAtMsSet;

        public Builder activity(AgentPresenceActivity value) {
            this.activity = value;
            this.activitySet = true;
            return this;
        }
        public Builder agent(String value) {
            this.agent = value;
            this.agentSet = true;
            return this;
        }
        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder line(UInt64 value) {
            this.line = value;
            this.lineSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder tool(String value) {
            this.tool = value;
            this.toolSet = true;
            return this;
        }
        public Builder updatedAtMs(UInt64 value) {
            this.updatedAtMs = value;
            this.updatedAtMsSet = true;
            return this;
        }
        public AgentPresenceChangedEvent build() { return new AgentPresenceChangedEvent(this); }
    }
}
