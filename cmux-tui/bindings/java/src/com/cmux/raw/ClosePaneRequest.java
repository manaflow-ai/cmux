// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-pane request. Protocol v5; authority: control. */
public final class ClosePaneRequest implements WireValue {
    private final UInt64 pane;

    private ClosePaneRequest(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }

    public static ClosePaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClosePaneRequest");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "ClosePaneRequest.pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClosePaneRequest that)) return false;
        return Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(pane); }

    @Override
    public String toString() { return "ClosePaneRequest" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public ClosePaneRequest build() { return new ClosePaneRequest(this); }
    }
}
