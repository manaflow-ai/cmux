// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ActivitySnapshot implements WireValue {
    private final long attachedClients;
    private final Field<UInt64> echoAtMs;
    private final Field<UInt64> echoInputAtMs;
    private final UInt64 lastAgentActionAtMs;
    private final Field<UInt64> lastPersonAttachAtMs;
    private final UInt64 lastUserInputAtMs;
    private final long liveAgents;

    private ActivitySnapshot(Builder builder) {
        if (!builder.attachedClientsSet) throw new IllegalArgumentException("attached_clients is required");
        this.attachedClients = builder.attachedClients;
        this.echoAtMs = builder.echoAtMs;
        this.echoInputAtMs = builder.echoInputAtMs;
        if (!builder.lastAgentActionAtMsSet) throw new IllegalArgumentException("last_agent_action_at_ms is required");
        this.lastAgentActionAtMs = builder.lastAgentActionAtMs;
        this.lastPersonAttachAtMs = builder.lastPersonAttachAtMs;
        if (!builder.lastUserInputAtMsSet) throw new IllegalArgumentException("last_user_input_at_ms is required");
        this.lastUserInputAtMs = builder.lastUserInputAtMs;
        if (!builder.liveAgentsSet) throw new IllegalArgumentException("live_agents is required");
        this.liveAgents = builder.liveAgents;
    }

    public static Builder builder() { return new Builder(); }

    public long attachedClients() { return attachedClients; }
    public Field<UInt64> echoAtMs() { return echoAtMs; }
    public Field<UInt64> echoInputAtMs() { return echoInputAtMs; }
    public UInt64 lastAgentActionAtMs() { return lastAgentActionAtMs; }
    public Field<UInt64> lastPersonAttachAtMs() { return lastPersonAttachAtMs; }
    public UInt64 lastUserInputAtMs() { return lastUserInputAtMs; }
    public long liveAgents() { return liveAgents; }

    public static ActivitySnapshot fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ActivitySnapshot");
        Builder builder = builder();
        Object rawAttachedClients = Wire.required(object, "attached_clients");
        builder.attachedClients(Wire.uint32(rawAttachedClients, "ActivitySnapshot.attached_clients"));
        Object rawEchoAtMs = Wire.optional(object, "echo_at_ms");
        if (!Wire.isMissing(rawEchoAtMs)) {
            builder.echoAtMs(rawEchoAtMs == null ? null : Wire.uint64(rawEchoAtMs, "ActivitySnapshot.echo_at_ms"));
        }
        Object rawEchoInputAtMs = Wire.optional(object, "echo_input_at_ms");
        if (!Wire.isMissing(rawEchoInputAtMs)) {
            builder.echoInputAtMs(rawEchoInputAtMs == null ? null : Wire.uint64(rawEchoInputAtMs, "ActivitySnapshot.echo_input_at_ms"));
        }
        Object rawLastAgentActionAtMs = Wire.required(object, "last_agent_action_at_ms");
        builder.lastAgentActionAtMs(rawLastAgentActionAtMs == null ? null : Wire.uint64(rawLastAgentActionAtMs, "ActivitySnapshot.last_agent_action_at_ms"));
        Object rawLastPersonAttachAtMs = Wire.optional(object, "last_person_attach_at_ms");
        if (!Wire.isMissing(rawLastPersonAttachAtMs)) {
            builder.lastPersonAttachAtMs(rawLastPersonAttachAtMs == null ? null : Wire.uint64(rawLastPersonAttachAtMs, "ActivitySnapshot.last_person_attach_at_ms"));
        }
        Object rawLastUserInputAtMs = Wire.required(object, "last_user_input_at_ms");
        builder.lastUserInputAtMs(rawLastUserInputAtMs == null ? null : Wire.uint64(rawLastUserInputAtMs, "ActivitySnapshot.last_user_input_at_ms"));
        Object rawLiveAgents = Wire.required(object, "live_agents");
        builder.liveAgents(Wire.uint32(rawLiveAgents, "ActivitySnapshot.live_agents"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "attached_clients", attachedClients);
        Wire.put(object, "echo_at_ms", echoAtMs);
        Wire.put(object, "echo_input_at_ms", echoInputAtMs);
        Wire.put(object, "last_agent_action_at_ms", lastAgentActionAtMs);
        Wire.put(object, "last_person_attach_at_ms", lastPersonAttachAtMs);
        Wire.put(object, "last_user_input_at_ms", lastUserInputAtMs);
        Wire.put(object, "live_agents", liveAgents);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ActivitySnapshot that)) return false;
        return Objects.equals(attachedClients, that.attachedClients) && Objects.equals(echoAtMs, that.echoAtMs) && Objects.equals(echoInputAtMs, that.echoInputAtMs) && Objects.equals(lastAgentActionAtMs, that.lastAgentActionAtMs) && Objects.equals(lastPersonAttachAtMs, that.lastPersonAttachAtMs) && Objects.equals(lastUserInputAtMs, that.lastUserInputAtMs) && Objects.equals(liveAgents, that.liveAgents);
    }

    @Override
    public int hashCode() { return Objects.hash(attachedClients, echoAtMs, echoInputAtMs, lastAgentActionAtMs, lastPersonAttachAtMs, lastUserInputAtMs, liveAgents); }

    @Override
    public String toString() { return "ActivitySnapshot" + toWire(); }

    public static final class Builder {
        private Long attachedClients;
        private boolean attachedClientsSet;
        private Field<UInt64> echoAtMs = Field.omitted();
        private Field<UInt64> echoInputAtMs = Field.omitted();
        private UInt64 lastAgentActionAtMs;
        private boolean lastAgentActionAtMsSet;
        private Field<UInt64> lastPersonAttachAtMs = Field.omitted();
        private UInt64 lastUserInputAtMs;
        private boolean lastUserInputAtMsSet;
        private Long liveAgents;
        private boolean liveAgentsSet;

        public Builder attachedClients(long value) {
            this.attachedClients = value;
            this.attachedClientsSet = true;
            return this;
        }
        public Builder echoAtMs(UInt64 value) {
            this.echoAtMs = Field.ofNullable(value);
            return this;
        }
        public Builder echoInputAtMs(UInt64 value) {
            this.echoInputAtMs = Field.ofNullable(value);
            return this;
        }
        public Builder lastAgentActionAtMs(UInt64 value) {
            this.lastAgentActionAtMs = value;
            this.lastAgentActionAtMsSet = true;
            return this;
        }
        public Builder lastPersonAttachAtMs(UInt64 value) {
            this.lastPersonAttachAtMs = Field.ofNullable(value);
            return this;
        }
        public Builder lastUserInputAtMs(UInt64 value) {
            this.lastUserInputAtMs = value;
            this.lastUserInputAtMsSet = true;
            return this;
        }
        public Builder liveAgents(long value) {
            this.liveAgents = value;
            this.liveAgentsSet = true;
            return this;
        }
        public ActivitySnapshot build() { return new ActivitySnapshot(this); }
    }
}
