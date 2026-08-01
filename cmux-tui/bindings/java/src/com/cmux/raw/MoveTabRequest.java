// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab request. Protocol v5; authority: control. */
public final class MoveTabRequest implements WireValue {
    private final Field<Boolean> activate;
    private final UInt64 index;
    private final UInt64 pane;
    private final UInt64 surface;

    private MoveTabRequest(Builder builder) {
        this.activate = builder.activate;
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public UInt64 index() { return index; }
    public UInt64 pane() { return pane; }
    public UInt64 surface() { return surface; }

    public static MoveTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "MoveTabRequest.activate"));
        }
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveTabRequest.index"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "MoveTabRequest.pane"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, index, pane, surface); }

    @Override
    public String toString() { return "MoveTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private UInt64 index;
        private boolean indexSet;
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder activate(Boolean value) {
            this.activate = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public MoveTabRequest build() { return new MoveTabRequest(this); }
    }
}
