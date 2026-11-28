// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ViewportSplitWidth implements WireValue {
    private final UInt64 split;
    private final double width;

    private ViewportSplitWidth(Builder builder) {
        if (!builder.splitSet) throw new IllegalArgumentException("split is required");
        this.split = Wire.nonNull(builder.split, "split");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 split() { return split; }
    public double width() { return width; }

    public static ViewportSplitWidth fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ViewportSplitWidth");
        Builder builder = builder();
        Object rawSplit = Wire.required(object, "split");
        builder.split(Wire.uint64(rawSplit, "ViewportSplitWidth.split"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "ViewportSplitWidth.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "split", split);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ViewportSplitWidth that)) return false;
        return Objects.equals(split, that.split) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(split, width); }

    @Override
    public String toString() { return "ViewportSplitWidth" + toWire(); }

    public static final class Builder {
        private UInt64 split;
        private boolean splitSet;
        private Double width;
        private boolean widthSet;

        public Builder split(UInt64 value) {
            this.split = value;
            this.splitSet = true;
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public ViewportSplitWidth build() { return new ViewportSplitWidth(this); }
    }
}
