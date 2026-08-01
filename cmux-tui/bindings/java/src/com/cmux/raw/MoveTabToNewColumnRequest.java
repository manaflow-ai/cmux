// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-new-column request. Protocol v10; authority: control. */
public final class MoveTabToNewColumnRequest implements WireValue {
    private final Field<Boolean> activate;
    private final UInt64 index;
    private final UInt64 surface;
    private final double width;

    private MoveTabToNewColumnRequest(Builder builder) {
        this.activate = builder.activate;
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public UInt64 index() { return index; }
    public UInt64 surface() { return surface; }
    public double width() { return width; }

    public static MoveTabToNewColumnRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToNewColumnRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "MoveTabToNewColumnRequest.activate"));
        }
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveTabToNewColumnRequest.index"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToNewColumnRequest.surface"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "MoveTabToNewColumnRequest.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "index", index);
        Wire.put(object, "surface", surface);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToNewColumnRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(index, that.index) && Objects.equals(surface, that.surface) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, index, surface, width); }

    @Override
    public String toString() { return "MoveTabToNewColumnRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private UInt64 index;
        private boolean indexSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Double width;
        private boolean widthSet;

        public Builder activate(Boolean value) {
            this.activate = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public MoveTabToNewColumnRequest build() { return new MoveTabToNewColumnRequest(this); }
    }
}
