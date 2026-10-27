// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-trust request. Protocol v12; authority: local-admin. */
public final class AgentSessionTrustRequest implements WireValue {
    /** An absolute folder of this machine, at most 4096 bytes, no control characters. */
    private final String cwd;
    /** The person chose the home folder as the chat's folder. */
    private final Field<Boolean> homeConfirmed;
    /** The person's answer; absent reads the folder's trust. unknown forgets the answer. */
    private final Field<AgentSessionTrustRequestLevel> level;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;

    private AgentSessionTrustRequest(Builder builder) {
        if (!builder.cwdSet) throw new IllegalArgumentException("cwd is required");
        this.cwd = Wire.nonNull(builder.cwd, "cwd");
        this.homeConfirmed = builder.homeConfirmed;
        this.level = builder.level;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String cwd() { return cwd; }
    public Field<Boolean> homeConfirmed() { return homeConfirmed; }
    public Field<AgentSessionTrustRequestLevel> level() { return level; }
    public UInt64 surface() { return surface; }

    public static AgentSessionTrustRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionTrustRequest");
        Builder builder = builder();
        Object rawCwd = Wire.required(object, "cwd");
        builder.cwd(Wire.string(rawCwd, "AgentSessionTrustRequest.cwd"));
        Object rawHomeConfirmed = Wire.optional(object, "home_confirmed");
        if (!Wire.isMissing(rawHomeConfirmed)) {
            builder.homeConfirmed(Wire.bool(rawHomeConfirmed, "AgentSessionTrustRequest.home_confirmed"));
        }
        Object rawLevel = Wire.optional(object, "level");
        if (!Wire.isMissing(rawLevel)) {
            builder.level(rawLevel == null ? null : AgentSessionTrustRequestLevel.fromWire(rawLevel));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionTrustRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "home_confirmed", homeConfirmed);
        Wire.put(object, "level", level);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionTrustRequest that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(homeConfirmed, that.homeConfirmed) && Objects.equals(level, that.level) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, homeConfirmed, level, surface); }

    @Override
    public String toString() { return "AgentSessionTrustRequest" + toWire(); }

    public static final class Builder {
        private String cwd;
        private boolean cwdSet;
        private Field<Boolean> homeConfirmed = Field.omitted();
        private Field<AgentSessionTrustRequestLevel> level = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cwd(String value) {
            this.cwd = value;
            this.cwdSet = true;
            return this;
        }
        public Builder homeConfirmed(Boolean value) {
            this.homeConfirmed = Field.of(value);
            return this;
        }
        public Builder level(AgentSessionTrustRequestLevel value) {
            this.level = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionTrustRequest build() { return new AgentSessionTrustRequest(this); }
    }
}
