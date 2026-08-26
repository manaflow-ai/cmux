// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DeclarativeLayoutSplit implements WireValue, DeclarativeLayout {
    private final DeclarativeLayout a;
    private final DeclarativeLayout b;
    private final SplitDirection dir;
    private final double ratio;

    private DeclarativeLayoutSplit(Builder builder) {
        if (!builder.aSet) throw new IllegalArgumentException("a is required");
        this.a = Wire.nonNull(builder.a, "a");
        if (!builder.bSet) throw new IllegalArgumentException("b is required");
        this.b = Wire.nonNull(builder.b, "b");
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.ratioSet) throw new IllegalArgumentException("ratio is required");
        this.ratio = builder.ratio;
    }

    public static Builder builder() { return new Builder(); }

    public DeclarativeLayout a() { return a; }
    public DeclarativeLayout b() { return b; }
    public SplitDirection dir() { return dir; }
    public double ratio() { return ratio; }
    public String type() { return "split"; }

    public static DeclarativeLayoutSplit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeclarativeLayoutSplit");
        Builder builder = builder();
        Object rawA = Wire.required(object, "a");
        builder.a(DeclarativeLayout.fromWire(rawA));
        Object rawB = Wire.required(object, "b");
        builder.b(DeclarativeLayout.fromWire(rawB));
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawRatio = Wire.required(object, "ratio");
        builder.ratio(Wire.float64(rawRatio, "DeclarativeLayoutSplit.ratio"));
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "split", "DeclarativeLayoutSplit.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "a", a);
        Wire.put(object, "b", b);
        Wire.put(object, "dir", dir);
        Wire.put(object, "ratio", ratio);
        Wire.put(object, "type", "split");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeclarativeLayoutSplit that)) return false;
        return Objects.equals(a, that.a) && Objects.equals(b, that.b) && Objects.equals(dir, that.dir) && Objects.equals(ratio, that.ratio);
    }

    @Override
    public int hashCode() { return Objects.hash(a, b, dir, ratio); }

    @Override
    public String toString() { return "DeclarativeLayoutSplit" + toWire(); }

    public static final class Builder {
        private DeclarativeLayout a;
        private boolean aSet;
        private DeclarativeLayout b;
        private boolean bSet;
        private SplitDirection dir;
        private boolean dirSet;
        private Double ratio;
        private boolean ratioSet;

        public Builder a(DeclarativeLayout value) {
            this.a = value;
            this.aSet = true;
            return this;
        }
        public Builder b(DeclarativeLayout value) {
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
        public DeclarativeLayoutSplit build() { return new DeclarativeLayoutSplit(this); }
    }
}
