// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable colors-changed event. Protocol v6; streams: attach-byte. */
public final class ColorsChangedEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final String bg;
    private final Field<String> cursor;
    private final Field<Boolean> cursorBlink;
    private final Field<CursorStyle> cursorStyle;
    private final String fg;
    private final Field<Map<String, String>> palette;
    private final String selectionBg;
    private final String selectionFg;
    private final Field<UInt64> surface;

    private ColorsChangedEvent(Builder builder) {
        if (!builder.bgSet) throw new IllegalArgumentException("bg is required");
        this.bg = builder.bg;
        this.cursor = builder.cursor;
        this.cursorBlink = builder.cursorBlink;
        this.cursorStyle = builder.cursorStyle;
        if (!builder.fgSet) throw new IllegalArgumentException("fg is required");
        this.fg = builder.fg;
        this.palette = builder.palette.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        if (!builder.selectionBgSet) throw new IllegalArgumentException("selection_bg is required");
        this.selectionBg = builder.selectionBg;
        if (!builder.selectionFgSet) throw new IllegalArgumentException("selection_fg is required");
        this.selectionFg = builder.selectionFg;
        this.surface = builder.surface;
    }

    public static Builder builder() { return new Builder(); }

    public String bg() { return bg; }
    public Field<String> cursor() { return cursor; }
    public Field<Boolean> cursorBlink() { return cursorBlink; }
    public Field<CursorStyle> cursorStyle() { return cursorStyle; }
    public String fg() { return fg; }
    public Field<Map<String, String>> palette() { return palette; }
    public String selectionBg() { return selectionBg; }
    public String selectionFg() { return selectionFg; }
    public Field<UInt64> surface() { return surface; }
    @Override public String event() { return "colors-changed"; }

    public static ColorsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ColorsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "colors-changed", "ColorsChangedEvent.event");
        Object rawBg = Wire.required(object, "bg");
        builder.bg(rawBg == null ? null : Wire.string(rawBg, "ColorsChangedEvent.bg"));
        Object rawCursor = Wire.optional(object, "cursor");
        if (!Wire.isMissing(rawCursor)) {
            builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "ColorsChangedEvent.cursor"));
        }
        Object rawCursorBlink = Wire.optional(object, "cursor_blink");
        if (!Wire.isMissing(rawCursorBlink)) {
            builder.cursorBlink(rawCursorBlink == null ? null : Wire.bool(rawCursorBlink, "ColorsChangedEvent.cursor_blink"));
        }
        Object rawCursorStyle = Wire.optional(object, "cursor_style");
        if (!Wire.isMissing(rawCursorStyle)) {
            builder.cursorStyle(rawCursorStyle == null ? null : CursorStyle.fromWire(rawCursorStyle));
        }
        Object rawFg = Wire.required(object, "fg");
        builder.fg(rawFg == null ? null : Wire.string(rawFg, "ColorsChangedEvent.fg"));
        Object rawPalette = Wire.optional(object, "palette");
        if (!Wire.isMissing(rawPalette)) {
            builder.palette(Wire.map(rawPalette, "ColorsChangedEvent.palette", item -> Wire.string(item, "ColorsChangedEvent.palette value")));
        }
        Object rawSelectionBg = Wire.required(object, "selection_bg");
        builder.selectionBg(rawSelectionBg == null ? null : Wire.string(rawSelectionBg, "ColorsChangedEvent.selection_bg"));
        Object rawSelectionFg = Wire.required(object, "selection_fg");
        builder.selectionFg(rawSelectionFg == null ? null : Wire.string(rawSelectionFg, "ColorsChangedEvent.selection_fg"));
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(Wire.uint64(rawSurface, "ColorsChangedEvent.surface"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "colors-changed");
        Wire.put(object, "bg", bg);
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "cursor_blink", cursorBlink);
        Wire.put(object, "cursor_style", cursorStyle);
        Wire.put(object, "fg", fg);
        Wire.put(object, "palette", palette);
        Wire.put(object, "selection_bg", selectionBg);
        Wire.put(object, "selection_fg", selectionFg);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ColorsChangedEvent that)) return false;
        return Objects.equals(bg, that.bg) && Objects.equals(cursor, that.cursor) && Objects.equals(cursorBlink, that.cursorBlink) && Objects.equals(cursorStyle, that.cursorStyle) && Objects.equals(fg, that.fg) && Objects.equals(palette, that.palette) && Objects.equals(selectionBg, that.selectionBg) && Objects.equals(selectionFg, that.selectionFg) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(bg, cursor, cursorBlink, cursorStyle, fg, palette, selectionBg, selectionFg, surface); }

    @Override
    public String toString() { return "ColorsChangedEvent" + toWire(); }

    public static final class Builder {
        private String bg;
        private boolean bgSet;
        private Field<String> cursor = Field.omitted();
        private Field<Boolean> cursorBlink = Field.omitted();
        private Field<CursorStyle> cursorStyle = Field.omitted();
        private String fg;
        private boolean fgSet;
        private Field<Map<String, String>> palette = Field.omitted();
        private String selectionBg;
        private boolean selectionBgSet;
        private String selectionFg;
        private boolean selectionFgSet;
        private Field<UInt64> surface = Field.omitted();

        public Builder bg(String value) {
            this.bg = value;
            this.bgSet = true;
            return this;
        }
        public Builder cursor(String value) {
            this.cursor = Field.ofNullable(value);
            return this;
        }
        public Builder cursorBlink(Boolean value) {
            this.cursorBlink = Field.ofNullable(value);
            return this;
        }
        public Builder cursorStyle(CursorStyle value) {
            this.cursorStyle = Field.ofNullable(value);
            return this;
        }
        public Builder fg(String value) {
            this.fg = value;
            this.fgSet = true;
            return this;
        }
        public Builder palette(Map<String, String> value) {
            this.palette = Field.of(value);
            return this;
        }
        public Builder selectionBg(String value) {
            this.selectionBg = value;
            this.selectionBgSet = true;
            return this;
        }
        public Builder selectionFg(String value) {
            this.selectionFg = value;
            this.selectionFgSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.of(value);
            return this;
        }
        public ColorsChangedEvent build() { return new ColorsChangedEvent(this); }
    }
}
