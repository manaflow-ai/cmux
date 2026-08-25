// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-ratio request. Protocol v5; authority: control. */
public final class SetRatioRequest implements WireValue {
    private final SplitDirection dir;
    private final UInt64 pane;
    private final double ratio;

    private SetRatioRequest(Builder builder) {
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.ratioSet) throw new IllegalArgumentException("ratio is required");
        this.ratio = builder.ratio;
    }

    public static Builder builder() { return new Builder(); }

    public SplitDirection dir() { return dir; }
    public UInt64 pane() { return pane; }
    public double ratio() { return ratio; }

    public static SetRatioRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetRatioRequest");
        Builder builder = builder();
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SetRatioRequest.pane"));
        Object rawRatio = Wire.required(object, "ratio");
        builder.ratio(Wire.float64(rawRatio, "SetRatioRequest.ratio"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "pane", pane);
        Wire.put(object, "ratio", ratio);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetRatioRequest that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(pane, that.pane) && Objects.equals(ratio, that.ratio);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, pane, ratio); }

    @Override
    public String toString() { return "SetRatioRequest" + toWire(); }

    public static final class Builder {
        private SplitDirection dir;
        private boolean dirSet;
        private UInt64 pane;
        private boolean paneSet;
        private Double ratio;
        private boolean ratioSet;

        public Builder dir(SplitDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder ratio(double value) {
            this.ratio = value;
            this.ratioSet = true;
            return this;
        }
        public SetRatioRequest build() { return new SetRatioRequest(this); }
    }
}
