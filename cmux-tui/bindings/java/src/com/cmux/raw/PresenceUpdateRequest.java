// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable presence-update request. Protocol v12; authority: control. */
public final class PresenceUpdateRequest implements WireValue {
    private final Field<PresenceHighlight> highlight;
    private final Field<PresenceAnchor> pointer;
    private final UInt64 surface;

    private PresenceUpdateRequest(Builder builder) {
        this.highlight = builder.highlight;
        this.pointer = builder.pointer;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<PresenceHighlight> highlight() { return highlight; }
    public Field<PresenceAnchor> pointer() { return pointer; }
    public UInt64 surface() { return surface; }

    public static PresenceUpdateRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceUpdateRequest");
        Builder builder = builder();
        Object rawHighlight = Wire.optional(object, "highlight");
        if (!Wire.isMissing(rawHighlight)) {
            builder.highlight(rawHighlight == null ? null : PresenceHighlight.fromWire(rawHighlight));
        }
        Object rawPointer = Wire.optional(object, "pointer");
        if (!Wire.isMissing(rawPointer)) {
            builder.pointer(rawPointer == null ? null : PresenceAnchor.fromWire(rawPointer));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "PresenceUpdateRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "highlight", highlight);
        Wire.put(object, "pointer", pointer);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceUpdateRequest that)) return false;
        return Objects.equals(highlight, that.highlight) && Objects.equals(pointer, that.pointer) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(highlight, pointer, surface); }

    @Override
    public String toString() { return "PresenceUpdateRequest" + toWire(); }

    public static final class Builder {
        private Field<PresenceHighlight> highlight = Field.omitted();
        private Field<PresenceAnchor> pointer = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder highlight(PresenceHighlight value) {
            this.highlight = Field.ofNullable(value);
            return this;
        }
        public Builder pointer(PresenceAnchor value) {
            this.pointer = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public PresenceUpdateRequest build() { return new PresenceUpdateRequest(this); }
    }
}
