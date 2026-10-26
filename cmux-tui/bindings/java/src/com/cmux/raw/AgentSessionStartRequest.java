// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-start request. Protocol v12; authority: local-admin. */
public final class AgentSessionStartRequest implements WireValue {
    /** An absolute folder of this machine, at most 4096 bytes. */
    private final String cwd;
    /** The agent kind acpmux resolves from its config: 1 to 64 letters, digits, '_', '.' or '-'. */
    private final Field<String> harness;
    /** The person chose the home folder as the chat's folder. */
    private final Field<Boolean> homeConfirmed;
    /** The acpmux run the caller holds a person key for: 1 to 128 of [A-Za-z0-9_.:-]. */
    private final Field<String> personInstance;
    /** Start only when acpmux holds a person key for person_instance (agent-session-start-keyed-reason-v1). */
    private final Field<Boolean> requirePersonKey;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;

    private AgentSessionStartRequest(Builder builder) {
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = Wire.nonNull(builder.cwd, "cwd");
        this.harness = builder.harness;
        this.homeConfirmed = builder.homeConfirmed;
        this.personInstance = builder.personInstance;
        this.requirePersonKey = builder.requirePersonKey;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String cwd() { return cwd; }
    public Field<String> harness() { return harness; }
    public Field<Boolean> homeConfirmed() { return homeConfirmed; }
    public Field<String> personInstance() { return personInstance; }
    public Field<Boolean> requirePersonKey() { return requirePersonKey; }
    public UInt64 surface() { return surface; }

    public static AgentSessionStartRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionStartRequest");
        Builder builder = builder();
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(Wire.string(rawCwd, "AgentSessionStartRequest.cwd"));
        Object rawHarness = Wire.optional(object, "harness");
        if (!Wire.isMissing(rawHarness)) {
            builder.harness(rawHarness == null ? null : Wire.string(rawHarness, "AgentSessionStartRequest.harness"));
        }
        Object rawHomeConfirmed = Wire.optional(object, "home_confirmed");
        if (!Wire.isMissing(rawHomeConfirmed)) {
            builder.homeConfirmed(Wire.bool(rawHomeConfirmed, "AgentSessionStartRequest.home_confirmed"));
        }
        Object rawPersonInstance = Wire.optional(object, "person_instance");
        if (!Wire.isMissing(rawPersonInstance)) {
            builder.personInstance(rawPersonInstance == null ? null : Wire.string(rawPersonInstance, "AgentSessionStartRequest.person_instance"));
        }
        Object rawRequirePersonKey = Wire.optional(object, "require_person_key");
        if (!Wire.isMissing(rawRequirePersonKey)) {
            builder.requirePersonKey(Wire.bool(rawRequirePersonKey, "AgentSessionStartRequest.require_person_key"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionStartRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "harness", harness);
        Wire.put(object, "home_confirmed", homeConfirmed);
        Wire.put(object, "person_instance", personInstance);
        Wire.put(object, "require_person_key", requirePersonKey);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionStartRequest that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(harness, that.harness) && Objects.equals(homeConfirmed, that.homeConfirmed) && Objects.equals(personInstance, that.personInstance) && Objects.equals(requirePersonKey, that.requirePersonKey) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, harness, homeConfirmed, personInstance, requirePersonKey, surface); }

    @Override
    public String toString() { return "AgentSessionStartRequest" + toWire(); }

    public static final class Builder {
        private String cwd;
        private boolean cwdSet;
        private Field<String> harness = Field.omitted();
        private Field<Boolean> homeConfirmed = Field.omitted();
        private Field<String> personInstance = Field.omitted();
        private Field<Boolean> requirePersonKey = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cwd(String value) {
            this.cwd = value;
            this.cwdSet = true;
            return this;
        }
        public Builder harness(String value) {
            this.harness = Field.ofNullable(value);
            return this;
        }
        public Builder homeConfirmed(Boolean value) {
            this.homeConfirmed = Field.of(value);
            return this;
        }
        public Builder personInstance(String value) {
            this.personInstance = Field.ofNullable(value);
            return this;
        }
        public Builder requirePersonKey(Boolean value) {
            this.requirePersonKey = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionStartRequest build() { return new AgentSessionStartRequest(this); }
    }
}
