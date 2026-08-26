// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-default-colors request. Protocol v5; authority: control. */
public final class SetDefaultColorsRequest implements WireValue {
    private final Field<String> bg;
    private final Field<Boolean> complete;
    private final Field<String> cursor;
    private final Field<Boolean> cursorBlink;
    private final Field<CursorStyle> cursorStyle;
    private final Field<String> fg;
    private final Field<Map<String, String>> palette;
    private final Field<String> selectionBg;
    private final Field<String> selectionFg;

    private SetDefaultColorsRequest(Builder builder) {
        this.bg = builder.bg;
        this.complete = builder.complete;
        this.cursor = builder.cursor;
        this.cursorBlink = builder.cursorBlink;
        this.cursorStyle = builder.cursorStyle;
        this.fg = builder.fg;
        this.palette = builder.palette.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.selectionBg = builder.selectionBg;
        this.selectionFg = builder.selectionFg;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> bg() { return bg; }
    public Field<Boolean> complete() { return complete; }
    public Field<String> cursor() { return cursor; }
    public Field<Boolean> cursorBlink() { return cursorBlink; }
    public Field<CursorStyle> cursorStyle() { return cursorStyle; }
    public Field<String> fg() { return fg; }
    public Field<Map<String, String>> palette() { return palette; }
    public Field<String> selectionBg() { return selectionBg; }
    public Field<String> selectionFg() { return selectionFg; }

    public static SetDefaultColorsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetDefaultColorsRequest");
        Builder builder = builder();
        Object rawBg = Wire.optional(object, "bg");
        if (!Wire.isMissing(rawBg)) {
            builder.bg(rawBg == null ? null : Wire.string(rawBg, "SetDefaultColorsRequest.bg"));
        }
        Object rawComplete = Wire.optional(object, "complete");
        if (!Wire.isMissing(rawComplete)) {
            builder.complete(Wire.bool(rawComplete, "SetDefaultColorsRequest.complete"));
        }
        Object rawCursor = Wire.optional(object, "cursor");
        if (!Wire.isMissing(rawCursor)) {
            builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "SetDefaultColorsRequest.cursor"));
        }
        Object rawCursorBlink = Wire.optional(object, "cursor_blink");
        if (!Wire.isMissing(rawCursorBlink)) {
            builder.cursorBlink(rawCursorBlink == null ? null : Wire.bool(rawCursorBlink, "SetDefaultColorsRequest.cursor_blink"));
        }
        Object rawCursorStyle = Wire.optional(object, "cursor_style");
        if (!Wire.isMissing(rawCursorStyle)) {
            builder.cursorStyle(rawCursorStyle == null ? null : CursorStyle.fromWire(rawCursorStyle));
        }
        Object rawFg = Wire.optional(object, "fg");
        if (!Wire.isMissing(rawFg)) {
            builder.fg(rawFg == null ? null : Wire.string(rawFg, "SetDefaultColorsRequest.fg"));
        }
        Object rawPalette = Wire.optional(object, "palette");
        if (!Wire.isMissing(rawPalette)) {
            builder.palette(rawPalette == null ? null : Wire.map(rawPalette, "SetDefaultColorsRequest.palette", item -> Wire.string(item, "SetDefaultColorsRequest.palette value")));
        }
        Object rawSelectionBg = Wire.optional(object, "selection_bg");
        if (!Wire.isMissing(rawSelectionBg)) {
            builder.selectionBg(rawSelectionBg == null ? null : Wire.string(rawSelectionBg, "SetDefaultColorsRequest.selection_bg"));
        }
        Object rawSelectionFg = Wire.optional(object, "selection_fg");
        if (!Wire.isMissing(rawSelectionFg)) {
            builder.selectionFg(rawSelectionFg == null ? null : Wire.string(rawSelectionFg, "SetDefaultColorsRequest.selection_fg"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bg", bg);
        Wire.put(object, "complete", complete);
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "cursor_blink", cursorBlink);
        Wire.put(object, "cursor_style", cursorStyle);
        Wire.put(object, "fg", fg);
        Wire.put(object, "palette", palette);
        Wire.put(object, "selection_bg", selectionBg);
        Wire.put(object, "selection_fg", selectionFg);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetDefaultColorsRequest that)) return false;
        return Objects.equals(bg, that.bg) && Objects.equals(complete, that.complete) && Objects.equals(cursor, that.cursor) && Objects.equals(cursorBlink, that.cursorBlink) && Objects.equals(cursorStyle, that.cursorStyle) && Objects.equals(fg, that.fg) && Objects.equals(palette, that.palette) && Objects.equals(selectionBg, that.selectionBg) && Objects.equals(selectionFg, that.selectionFg);
    }

    @Override
    public int hashCode() { return Objects.hash(bg, complete, cursor, cursorBlink, cursorStyle, fg, palette, selectionBg, selectionFg); }

    @Override
    public String toString() { return "SetDefaultColorsRequest" + toWire(); }

    public static final class Builder {
        private Field<String> bg = Field.omitted();
        private Field<Boolean> complete = Field.omitted();
        private Field<String> cursor = Field.omitted();
        private Field<Boolean> cursorBlink = Field.omitted();
        private Field<CursorStyle> cursorStyle = Field.omitted();
        private Field<String> fg = Field.omitted();
        private Field<Map<String, String>> palette = Field.omitted();
        private Field<String> selectionBg = Field.omitted();
        private Field<String> selectionFg = Field.omitted();

        public Builder bg(String value) {
            this.bg = Field.ofNullable(value);
            return this;
        }
        public Builder complete(Boolean value) {
            this.complete = Field.of(value);
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
            this.fg = Field.ofNullable(value);
            return this;
        }
        public Builder palette(Map<String, String> value) {
            this.palette = Field.ofNullable(value);
            return this;
        }
        public Builder selectionBg(String value) {
            this.selectionBg = Field.ofNullable(value);
            return this;
        }
        public Builder selectionFg(String value) {
            this.selectionFg = Field.ofNullable(value);
            return this;
        }
        public SetDefaultColorsRequest build() { return new SetDefaultColorsRequest(this); }
    }
}
