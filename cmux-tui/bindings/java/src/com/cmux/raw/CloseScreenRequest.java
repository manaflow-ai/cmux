// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-screen request. Protocol v5; authority: control. */
public final class CloseScreenRequest implements WireValue {
    private final Field<Boolean> endTerminals;
    private final UInt64 screen;

    private CloseScreenRequest(Builder builder) {
        this.endTerminals = builder.endTerminals;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> endTerminals() { return endTerminals; }
    public UInt64 screen() { return screen; }

    public static CloseScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseScreenRequest");
        Builder builder = builder();
        Object rawEndTerminals = Wire.optional(object, "end_terminals");
        if (!Wire.isMissing(rawEndTerminals)) {
            builder.endTerminals(Wire.bool(rawEndTerminals, "CloseScreenRequest.end_terminals"));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "CloseScreenRequest.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end_terminals", endTerminals);
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseScreenRequest that)) return false;
        return Objects.equals(endTerminals, that.endTerminals) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(endTerminals, screen); }

    @Override
    public String toString() { return "CloseScreenRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> endTerminals = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;

        public Builder endTerminals(Boolean value) {
            this.endTerminals = Field.of(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public CloseScreenRequest build() { return new CloseScreenRequest(this); }
    }
}
