// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-pane-to-new-column request. Protocol v10; authority: control. */
public final class MovePaneToNewColumnRequest implements WireValue {
    private final Field<Boolean> activate;
    private final UInt64 index;
    private final UInt64 pane;
    private final double width;

    private MovePaneToNewColumnRequest(Builder builder) {
        this.activate = builder.activate;
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public UInt64 index() { return index; }
    public UInt64 pane() { return pane; }
    public double width() { return width; }

    public static MovePaneToNewColumnRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MovePaneToNewColumnRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "MovePaneToNewColumnRequest.activate"));
        }
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MovePaneToNewColumnRequest.index"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "MovePaneToNewColumnRequest.pane"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "MovePaneToNewColumnRequest.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MovePaneToNewColumnRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, index, pane, width); }

    @Override
    public String toString() { return "MovePaneToNewColumnRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private UInt64 index;
        private boolean indexSet;
        private UInt64 pane;
        private boolean paneSet;
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
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public MovePaneToNewColumnRequest build() { return new MovePaneToNewColumnRequest(this); }
    }
}
