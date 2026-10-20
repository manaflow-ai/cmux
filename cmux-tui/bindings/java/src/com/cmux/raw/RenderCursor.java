// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderCursor implements WireValue {
    private final boolean blink;
    private final String color;
    private final CursorStyle style;
    private final boolean visible;
    private final int x;
    private final int y;

    private RenderCursor(Builder builder) {
        if (!builder.blinkSet) throw new IllegalArgumentException("blink is required");
        this.blink = builder.blink;
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = builder.color;
        if (!builder.styleSet) throw new IllegalArgumentException("style is required");
        this.style = Wire.nonNull(builder.style, "style");
        if (!builder.visibleSet) throw new IllegalArgumentException("visible is required");
        this.visible = builder.visible;
        if (!builder.xSet) throw new IllegalArgumentException("x is required");
        this.x = builder.x;
        if (!builder.ySet) throw new IllegalArgumentException("y is required");
        this.y = builder.y;
    }

    public static Builder builder() { return new Builder(); }

    public boolean blink() { return blink; }
    public String color() { return color; }
    public CursorStyle style() { return style; }
    public boolean visible() { return visible; }
    public int x() { return x; }
    public int y() { return y; }

    public static RenderCursor fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderCursor");
        Builder builder = builder();
        Object rawBlink = Wire.required(object, "blink");
        builder.blink(Wire.bool(rawBlink, "RenderCursor.blink"));
        Object rawColor = Wire.required(object, "color");
        builder.color(rawColor == null ? null : Wire.string(rawColor, "RenderCursor.color"));
        Object rawStyle = Wire.required(object, "style");
        builder.style(CursorStyle.fromWire(rawStyle));
        Object rawVisible = Wire.required(object, "visible");
        builder.visible(Wire.bool(rawVisible, "RenderCursor.visible"));
        Object rawX = Wire.required(object, "x");
        builder.x(Wire.uint16(rawX, "RenderCursor.x"));
        Object rawY = Wire.required(object, "y");
        builder.y(Wire.uint16(rawY, "RenderCursor.y"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "blink", blink);
        Wire.put(object, "color", color);
        Wire.put(object, "style", style);
        Wire.put(object, "visible", visible);
        Wire.put(object, "x", x);
        Wire.put(object, "y", y);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderCursor that)) return false;
        return Objects.equals(blink, that.blink) && Objects.equals(color, that.color) && Objects.equals(style, that.style) && Objects.equals(visible, that.visible) && Objects.equals(x, that.x) && Objects.equals(y, that.y);
    }

    @Override
    public int hashCode() { return Objects.hash(blink, color, style, visible, x, y); }

    @Override
    public String toString() { return "RenderCursor" + toWire(); }

    public static final class Builder {
        private Boolean blink;
        private boolean blinkSet;
        private String color;
        private boolean colorSet;
        private CursorStyle style;
        private boolean styleSet;
        private Boolean visible;
        private boolean visibleSet;
        private Integer x;
        private boolean xSet;
        private Integer y;
        private boolean ySet;

        public Builder blink(boolean value) {
            this.blink = value;
            this.blinkSet = true;
            return this;
        }
        public Builder color(String value) {
            this.color = value;
            this.colorSet = true;
            return this;
        }
        public Builder style(CursorStyle value) {
            this.style = value;
            this.styleSet = true;
            return this;
        }
        public Builder visible(boolean value) {
            this.visible = value;
            this.visibleSet = true;
            return this;
        }
        public Builder x(int value) {
            this.x = value;
            this.xSet = true;
            return this;
        }
        public Builder y(int value) {
            this.y = value;
            this.ySet = true;
            return this;
        }
        public RenderCursor build() { return new RenderCursor(this); }
    }
}
