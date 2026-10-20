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
    private final UInt64 screen;

    private CloseScreenRequest(Builder builder) {
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 screen() { return screen; }

    public static CloseScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseScreenRequest");
        Builder builder = builder();
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "CloseScreenRequest.screen"));
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
        if (!(other instanceof CloseScreenRequest that)) return false;
        return Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(screen); }

    @Override
    public String toString() { return "CloseScreenRequest" + toWire(); }

    public static final class Builder {
        private UInt64 screen;
        private boolean screenSet;

        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public CloseScreenRequest build() { return new CloseScreenRequest(this); }
    }
}
