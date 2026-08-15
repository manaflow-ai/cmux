// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutSplit implements WireValue, Layout {
    private final Layout a;
    private final Layout b;
    private final SplitDirection dir;
    private final double ratio;
    /** Stable for the lifetime of this split node. */
    private final Field<UInt64> split;

    private LayoutSplit(Builder builder) {
        if (!builder.aSet) throw new IllegalArgumentException("a is required");
        this.a = Wire.nonNull(builder.a, "a");
        if (!builder.bSet) throw new IllegalArgumentException("b is required");
        this.b = Wire.nonNull(builder.b, "b");
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.ratioSet) throw new IllegalArgumentException("ratio is required");
        this.ratio = builder.ratio;
        this.split = builder.split;
    }

    public static Builder builder() { return new Builder(); }

    public Layout a() { return a; }
    public Layout b() { return b; }
    public SplitDirection dir() { return dir; }
    public double ratio() { return ratio; }
    public Field<UInt64> split() { return split; }
    public String type() { return "split"; }

    public static LayoutSplit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutSplit");
        Builder builder = builder();
        Object rawA = Wire.required(object, "a");
        builder.a(Layout.fromWire(rawA));
        Object rawB = Wire.required(object, "b");
        builder.b(Layout.fromWire(rawB));
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawRatio = Wire.required(object, "ratio");
        builder.ratio(Wire.float64(rawRatio, "LayoutSplit.ratio"));
        Object rawSplit = Wire.optional(object, "split");
        if (!Wire.isMissing(rawSplit)) {
            builder.split(Wire.uint64(rawSplit, "LayoutSplit.split"));
        }
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "split", "LayoutSplit.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "a", a);
        Wire.put(object, "b", b);
        Wire.put(object, "dir", dir);
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "split", split);
        Wire.put(object, "type", "split");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutSplit that)) return false;
        return Objects.equals(a, that.a) && Objects.equals(b, that.b) && Objects.equals(dir, that.dir) && Objects.equals(ratio, that.ratio) && Objects.equals(split, that.split);
    }

    @Override
    public int hashCode() { return Objects.hash(a, b, dir, ratio, split); }

    @Override
    public String toString() { return "LayoutSplit" + toWire(); }

    public static final class Builder {
        private Layout a;
        private boolean aSet;
        private Layout b;
        private boolean bSet;
        private SplitDirection dir;
        private boolean dirSet;
        private Double ratio;
        private boolean ratioSet;
        private Field<UInt64> split = Field.omitted();

        public Builder a(Layout value) {
            this.a = value;
            this.aSet = true;
            return this;
        }
        public Builder b(Layout value) {
            this.b = value;
            this.bSet = true;
            return this;
        }
        public Builder dir(SplitDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder ratio(double value) {
            this.ratio = value;
            this.ratioSet = true;
            return this;
        }
        public Builder split(UInt64 value) {
            this.split = Field.of(value);
            return this;
        }
        public LayoutSplit build() { return new LayoutSplit(this); }
    }
}
