// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutRowNode implements WireValue {
    private final UInt64 height;
    private final UInt64 id;
    private final Layout layout;

    private LayoutRowNode(Builder builder) {
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = Wire.nonNull(builder.height, "height");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 height() { return height; }
    public UInt64 id() { return id; }
    public Layout layout() { return layout; }

    public static LayoutRowNode fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutRowNode");
        Builder builder = builder();
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint64(rawHeight, "LayoutRowNode.height"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "LayoutRowNode.id"));
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height", height);
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutRowNode that)) return false;
        return Objects.equals(height, that.height) && Objects.equals(id, that.id) && Objects.equals(layout, that.layout);
    }

    @Override
    public int hashCode() { return Objects.hash(height, id, layout); }

    @Override
    public String toString() { return "LayoutRowNode" + toWire(); }

    public static final class Builder {
        private UInt64 height;
        private boolean heightSet;
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;

        public Builder height(UInt64 value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
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
        public LayoutRowNode build() { return new LayoutRowNode(this); }
    }
}
