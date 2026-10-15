// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientAttentionInput implements WireValue {
    /** Milliseconds since the last keystroke in that tab; capped at one day. */
    private final UInt64 msAgo;
    /** A tab the user typed in. */
    private final UInt64 surface;

    private ClientAttentionInput(Builder builder) {
        if (!builder.msAgoSet) throw new IllegalArgumentException("ms_ago is required");
        this.msAgo = Wire.nonNull(builder.msAgo, "ms_ago");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 msAgo() { return msAgo; }
    public UInt64 surface() { return surface; }

    public static ClientAttentionInput fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientAttentionInput");
        Builder builder = builder();
        Object rawMsAgo = Wire.required(object, "ms_ago");
        builder.msAgo(Wire.uint64(rawMsAgo, "ClientAttentionInput.ms_ago"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ClientAttentionInput.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ms_ago", msAgo);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientAttentionInput that)) return false;
        return Objects.equals(msAgo, that.msAgo) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(msAgo, surface); }

    @Override
    public String toString() { return "ClientAttentionInput" + toWire(); }

    public static final class Builder {
        private UInt64 msAgo;
        private boolean msAgoSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder msAgo(UInt64 value) {
            this.msAgo = value;
            this.msAgoSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ClientAttentionInput build() { return new ClientAttentionInput(this); }
    }
}
