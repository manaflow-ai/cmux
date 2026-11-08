// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable zoom-pane request. Protocol v6; authority: control. */
public final class ZoomPaneRequest implements WireValue {
    private final Field<ZoomPaneRequestMode> mode;
    private final Field<UInt64> pane;

    private ZoomPaneRequest(Builder builder) {
        this.mode = builder.mode;
        this.pane = builder.pane;
    }

    public static Builder builder() { return new Builder(); }

    public Field<ZoomPaneRequestMode> mode() { return mode; }
    public Field<UInt64> pane() { return pane; }

    public static ZoomPaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ZoomPaneRequest");
        Builder builder = builder();
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : ZoomPaneRequestMode.fromWire(rawMode));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "ZoomPaneRequest.pane"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mode", mode);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ZoomPaneRequest that)) return false;
        return Objects.equals(mode, that.mode) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(mode, pane); }

    @Override
    public String toString() { return "ZoomPaneRequest" + toWire(); }

    public static final class Builder {
        private Field<ZoomPaneRequestMode> mode = Field.omitted();
        private Field<UInt64> pane = Field.omitted();

        public Builder mode(ZoomPaneRequestMode value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public ZoomPaneRequest build() { return new ZoomPaneRequest(this); }
    }
}
