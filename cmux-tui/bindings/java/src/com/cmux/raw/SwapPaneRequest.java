// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable swap-pane request. Protocol v6; authority: control. */
public final class SwapPaneRequest implements WireValue {
    private final Field<PaneDirection> dir;
    private final UInt64 pane;
    private final Field<UInt64> target;

    private SwapPaneRequest(Builder builder) {
        this.dir = builder.dir;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.target = builder.target;
    }

    public static Builder builder() { return new Builder(); }

    public Field<PaneDirection> dir() { return dir; }
    public UInt64 pane() { return pane; }
    public Field<UInt64> target() { return target; }

    public static SwapPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SwapPaneRequest");
        Builder builder = builder();
        Object rawDir = Wire.optional(object, "dir");
        if (!Wire.isMissing(rawDir)) {
            builder.dir(rawDir == null ? null : PaneDirection.fromWire(rawDir));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SwapPaneRequest.pane"));
        Object rawTarget = Wire.optional(object, "target");
        if (!Wire.isMissing(rawTarget)) {
            builder.target(rawTarget == null ? null : Wire.uint64(rawTarget, "SwapPaneRequest.target"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "pane", pane);
        Wire.put(object, "target", target);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SwapPaneRequest that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(pane, that.pane) && Objects.equals(target, that.target);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, pane, target); }

    @Override
    public String toString() { return "SwapPaneRequest" + toWire(); }

    public static final class Builder {
        private Field<PaneDirection> dir = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<UInt64> target = Field.omitted();

        public Builder dir(PaneDirection value) {
            this.dir = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder target(UInt64 value) {
            this.target = Field.ofNullable(value);
            return this;
        }
        public SwapPaneRequest build() { return new SwapPaneRequest(this); }
    }
}
