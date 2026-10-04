// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SetViewportPaneWidthResult implements WireValue {
    private final double width;

    private SetViewportPaneWidthResult(Builder builder) {
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public double width() { return width; }

    public static SetViewportPaneWidthResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetViewportPaneWidthResult");
        Builder builder = builder();
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "SetViewportPaneWidthResult.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetViewportPaneWidthResult that)) return false;
        return Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(width); }

    @Override
    public String toString() { return "SetViewportPaneWidthResult" + toWire(); }

    public static final class Builder {
        private Double width;
        private boolean widthSet;

        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public SetViewportPaneWidthResult build() { return new SetViewportPaneWidthResult(this); }
    }
}
