// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable rename-screen request. Protocol v5; authority: control. */
public final class RenameScreenRequest implements WireValue {
    private final String name;
    private final UInt64 screen;

    private RenameScreenRequest(Builder builder) {
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public String name() { return name; }
    public UInt64 screen() { return screen; }

    public static RenameScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenameScreenRequest");
        Builder builder = builder();
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "RenameScreenRequest.name"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "RenameScreenRequest.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenameScreenRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(name, screen); }

    @Override
    public String toString() { return "RenameScreenRequest" + toWire(); }

    public static final class Builder {
        private String name;
        private boolean nameSet;
        private UInt64 screen;
        private boolean screenSet;

        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public RenameScreenRequest build() { return new RenameScreenRequest(this); }
    }
}
