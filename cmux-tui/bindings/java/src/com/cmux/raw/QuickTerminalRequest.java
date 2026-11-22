// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable quick-terminal request. Protocol v12; authority: control. */
public final class QuickTerminalRequest implements WireValue {
    private final Field<Double> h;
    private final Field<String> mode;
    private final UInt64 screen;
    private final Field<Double> w;
    private final Field<Double> x;
    private final Field<Double> y;

    private QuickTerminalRequest(Builder builder) {
        this.h = builder.h;
        this.mode = builder.mode;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        this.w = builder.w;
        this.x = builder.x;
        this.y = builder.y;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Double> h() { return h; }
    public Field<String> mode() { return mode; }
    public UInt64 screen() { return screen; }
    public Field<Double> w() { return w; }
    public Field<Double> x() { return x; }
    public Field<Double> y() { return y; }

    public static QuickTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "QuickTerminalRequest");
        Builder builder = builder();
        Object rawH = Wire.optional(object, "h");
        if (!Wire.isMissing(rawH)) {
            builder.h(rawH == null ? null : Wire.float64(rawH, "QuickTerminalRequest.h"));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(rawMode == null ? null : Wire.string(rawMode, "QuickTerminalRequest.mode"));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "QuickTerminalRequest.screen"));
        Object rawW = Wire.optional(object, "w");
        if (!Wire.isMissing(rawW)) {
            builder.w(rawW == null ? null : Wire.float64(rawW, "QuickTerminalRequest.w"));
        }
        Object rawX = Wire.optional(object, "x");
        if (!Wire.isMissing(rawX)) {
            builder.x(rawX == null ? null : Wire.float64(rawX, "QuickTerminalRequest.x"));
        }
        Object rawY = Wire.optional(object, "y");
        if (!Wire.isMissing(rawY)) {
            builder.y(rawY == null ? null : Wire.float64(rawY, "QuickTerminalRequest.y"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "h", h);
        Wire.put(object, "mode", mode);
        Wire.put(object, "screen", screen);
        Wire.put(object, "w", w);
        Wire.put(object, "x", x);
        Wire.put(object, "y", y);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof QuickTerminalRequest that)) return false;
        return Objects.equals(h, that.h) && Objects.equals(mode, that.mode) && Objects.equals(screen, that.screen) && Objects.equals(w, that.w) && Objects.equals(x, that.x) && Objects.equals(y, that.y);
    }

    @Override
    public int hashCode() { return Objects.hash(h, mode, screen, w, x, y); }

    @Override
    public String toString() { return "QuickTerminalRequest" + toWire(); }

    public static final class Builder {
        private Field<Double> h = Field.omitted();
        private Field<String> mode = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;
        private Field<Double> w = Field.omitted();
        private Field<Double> x = Field.omitted();
        private Field<Double> y = Field.omitted();

        public Builder h(Double value) {
            this.h = Field.ofNullable(value);
            return this;
        }
        public Builder mode(String value) {
            this.mode = Field.ofNullable(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public Builder w(Double value) {
            this.w = Field.ofNullable(value);
            return this;
        }
        public Builder x(Double value) {
            this.x = Field.ofNullable(value);
            return this;
        }
        public Builder y(Double value) {
            this.y = Field.ofNullable(value);
            return this;
        }
        public QuickTerminalRequest build() { return new QuickTerminalRequest(this); }
    }
}
