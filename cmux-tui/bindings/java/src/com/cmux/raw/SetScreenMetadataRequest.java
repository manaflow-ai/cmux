// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-screen-metadata request. Protocol v12; authority: control. */
public final class SetScreenMetadataRequest implements WireValue {
    private final Field<String> color;
    private final Field<String> icon;
    private final UInt64 screen;

    private SetScreenMetadataRequest(Builder builder) {
        this.color = builder.color;
        this.icon = builder.icon;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> color() { return color; }
    public Field<String> icon() { return icon; }
    public UInt64 screen() { return screen; }

    public static SetScreenMetadataRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetScreenMetadataRequest");
        Builder builder = builder();
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "SetScreenMetadataRequest.color"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "SetScreenMetadataRequest.icon"));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "SetScreenMetadataRequest.screen"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "icon", icon);
        Wire.put(object, "screen", screen);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetScreenMetadataRequest that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(icon, that.icon) && Objects.equals(screen, that.screen);
    }

    @Override
    public int hashCode() { return Objects.hash(color, icon, screen); }

    @Override
    public String toString() { return "SetScreenMetadataRequest" + toWire(); }

    public static final class Builder {
        private Field<String> color = Field.omitted();
        private Field<String> icon = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;

        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public SetScreenMetadataRequest build() { return new SetScreenMetadataRequest(this); }
    }
}
