// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable export-layout request. Protocol v6; authority: control. */
public final class ExportLayoutRequest implements WireValue {
    private final Field<UInt64> screen;

    private ExportLayoutRequest(Builder builder) {
        this.screen = builder.screen;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> screen() { return screen; }

    public static ExportLayoutRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ExportLayoutRequest");
        Builder builder = builder();
        Object rawScreen = Wire.optional(object, "screen");
        if (!Wire.isMissing(rawScreen)) {
            builder.screen(rawScreen == null ? null : Wire.uint64(rawScreen, "ExportLayoutRequest.screen"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ExportLayoutRequest that)) return false;
        return Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(screen); }

    @Override
    public String toString() { return "ExportLayoutRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> screen = Field.omitted();

        public Builder screen(UInt64 value) {
            this.screen = Field.ofNullable(value);
            return this;
        }
        public ExportLayoutRequest build() { return new ExportLayoutRequest(this); }
    }
}
