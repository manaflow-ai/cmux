// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutSizeSplitRatio implements WireValue {
    private final double ratio;
    private final UInt64 split;

    private LayoutSizeSplitRatio(Builder builder) {
        if (!builder.ratioSet) throw new IllegalArgumentException("ratio is required");
        this.ratio = builder.ratio;
        if (!builder.splitSet) throw new IllegalArgumentException("split is required");
        this.split = Wire.nonNull(builder.split, "split");
    }

    public static Builder builder() { return new Builder(); }

    public double ratio() { return ratio; }
    public UInt64 split() { return split; }

    public static LayoutSizeSplitRatio fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutSizeSplitRatio");
        Builder builder = builder();
        Object rawRatio = Wire.required(object, "ratio");
        builder.ratio(Wire.float64(rawRatio, "LayoutSizeSplitRatio.ratio"));
        Object rawSplit = Wire.required(object, "split");
        builder.split(Wire.uint64(rawSplit, "LayoutSizeSplitRatio.split"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "split", split);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutSizeSplitRatio that)) return false;
        return Objects.equals(ratio, that.ratio) && Objects.equals(split, that.split);
    }

    @Override
    public int hashCode() { return Objects.hash(ratio, split); }

    @Override
    public String toString() { return "LayoutSizeSplitRatio" + toWire(); }

    public static final class Builder {
        private Double ratio;
        private boolean ratioSet;
        private UInt64 split;
        private boolean splitSet;

        public Builder ratio(double value) {
            this.ratio = value;
            this.ratioSet = true;
            return this;
        }
        public Builder split(UInt64 value) {
            this.split = value;
            this.splitSet = true;
            return this;
        }
        public LayoutSizeSplitRatio build() { return new LayoutSizeSplitRatio(this); }
    }
}
