// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable focus-pane request. Protocol v5; authority: control. */
public final class FocusPaneRequest implements WireValue {
    private final UInt64 pane;

    private FocusPaneRequest(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }

    public static FocusPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FocusPaneRequest");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "FocusPaneRequest.pane"));
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
        if (!(other instanceof FocusPaneRequest that)) return false;
        return Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(pane); }

    @Override
    public String toString() { return "FocusPaneRequest" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public FocusPaneRequest build() { return new FocusPaneRequest(this); }
    }
}
