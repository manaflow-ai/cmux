// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-media request. Protocol v12; authority: local-admin. */
public final class AgentSessionMediaRequest implements WireValue {
    /** An image the session wrote: png, jpg, jpeg, gif or webp, at most 4096 bytes. */
    private final String path;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;

    private AgentSessionMediaRequest(Builder builder) {
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String path() { return path; }
    public UInt64 surface() { return surface; }

    public static AgentSessionMediaRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionMediaRequest");
        Builder builder = builder();
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "AgentSessionMediaRequest.path"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionMediaRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "path", path);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionMediaRequest that)) return false;
        return Objects.equals(path, that.path) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(path, surface); }

    @Override
    public String toString() { return "AgentSessionMediaRequest" + toWire(); }

    public static final class Builder {
        private String path;
        private boolean pathSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public AgentSessionMediaRequest build() { return new AgentSessionMediaRequest(this); }
    }
}
