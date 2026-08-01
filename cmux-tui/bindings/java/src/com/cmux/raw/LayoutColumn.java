// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutColumn implements WireValue {
    private final UInt64 id;
    private final Layout layout;
    private final double width;

    private LayoutColumn(Builder builder) {
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 id() { return id; }
    public Layout layout() { return layout; }
    public double width() { return width; }

    public static LayoutColumn fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutColumn");
        Builder builder = builder();
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "LayoutColumn.id"));
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "LayoutColumn.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutColumn that)) return false;
        return Objects.equals(id, that.id) && Objects.equals(layout, that.layout) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(id, layout, width); }

    @Override
    public String toString() { return "LayoutColumn" + toWire(); }

    public static final class Builder {
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;
        private Double width;
        private boolean widthSet;

        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder layout(Layout value) {
            this.layout = value;
            this.layoutSet = true;
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public LayoutColumn build() { return new LayoutColumn(this); }
    }
}
