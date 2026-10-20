// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable focus-direction request. Protocol v6; authority: control. */
public final class FocusDirectionRequest implements WireValue {
    private final PaneDirection dir;
    private final Field<UInt64> pane;

    private FocusDirectionRequest(Builder builder) {
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        this.pane = builder.pane;
    }

    public static Builder builder() { return new Builder(); }

    public PaneDirection dir() { return dir; }
    public Field<UInt64> pane() { return pane; }

    public static FocusDirectionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FocusDirectionRequest");
        Builder builder = builder();
        Object rawDir = Wire.required(object, "dir");
        builder.dir(PaneDirection.fromWire(rawDir));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "FocusDirectionRequest.pane"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FocusDirectionRequest that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, pane); }

    @Override
    public String toString() { return "FocusDirectionRequest" + toWire(); }

    public static final class Builder {
        private PaneDirection dir;
        private boolean dirSet;
        private Field<UInt64> pane = Field.omitted();

        public Builder dir(PaneDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public FocusDirectionRequest build() { return new FocusDirectionRequest(this); }
    }
}
