// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-screen-pinned request. Protocol v12; authority: control. */
public final class SetScreenPinnedRequest implements WireValue {
    private final boolean pinned;
    private final UInt64 screen;

    private SetScreenPinnedRequest(Builder builder) {
        if (!builder.pinnedSet) throw new IllegalArgumentException("pinned is required");
        this.pinned = builder.pinned;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public boolean pinned() { return pinned; }
    public UInt64 screen() { return screen; }

    public static SetScreenPinnedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetScreenPinnedRequest");
        Builder builder = builder();
        Object rawPinned = Wire.required(object, "pinned");
        builder.pinned(Wire.bool(rawPinned, "SetScreenPinnedRequest.pinned"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "SetScreenPinnedRequest.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetScreenPinnedRequest that)) return false;
        return Objects.equals(pinned, that.pinned) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(pinned, screen); }

    @Override
    public String toString() { return "SetScreenPinnedRequest" + toWire(); }

    public static final class Builder {
        private Boolean pinned;
        private boolean pinnedSet;
        private UInt64 screen;
        private boolean screenSet;

        public Builder pinned(boolean value) {
            this.pinned = value;
            this.pinnedSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public SetScreenPinnedRequest build() { return new SetScreenPinnedRequest(this); }
    }
}
