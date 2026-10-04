// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionSource implements WireValue {
    /** The agent kind the chat was started with. */
    private final Field<String> harness;
    /** install: and the stable install id of the machine whose acpmux runs the session. */
    private final String host;
    /** The acpmux session id; null for a new chat until bind-conversation-tab-session. */
    private final Field<String> session;

    private AgentSessionSource(Builder builder) {
        this.harness = builder.harness;
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = Wire.nonNull(builder.host, "host");
        this.session = builder.session;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> harness() { return harness; }
    public String host() { return host; }
    public Field<String> session() { return session; }

    public static AgentSessionSource fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionSource");
        Builder builder = builder();
        Object rawHarness = Wire.optional(object, "harness");
        if (!Wire.isMissing(rawHarness)) {
            builder.harness(rawHarness == null ? null : Wire.string(rawHarness, "AgentSessionSource.harness"));
        }
        Object rawHost = Wire.required(object, "host");
        builder.host(Wire.string(rawHost, "AgentSessionSource.host"));
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(rawSession == null ? null : Wire.string(rawSession, "AgentSessionSource.session"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "harness", harness);
        Wire.put(object, "host", host);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionSource that)) return false;
        return Objects.equals(harness, that.harness) && Objects.equals(host, that.host) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(harness, host, session); }

    @Override
    public String toString() { return "AgentSessionSource" + toWire(); }

    public static final class Builder {
        private Field<String> harness = Field.omitted();
        private String host;
        private boolean hostSet;
        private Field<String> session = Field.omitted();

        public Builder harness(String value) {
            this.harness = Field.ofNullable(value);
            return this;
        }
        public Builder host(String value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder session(String value) {
            this.session = Field.ofNullable(value);
            return this;
        }
        public AgentSessionSource build() { return new AgentSessionSource(this); }
    }
}
