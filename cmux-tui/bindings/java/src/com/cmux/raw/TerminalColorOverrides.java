// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalColorOverrides implements WireValue {
    private final String bg;
    private final String cursor;
    private final String fg;

    private TerminalColorOverrides(Builder builder) {
        if (!builder.bgSet) throw new IllegalArgumentException("bg is required");
        this.bg = builder.bg;
        if (!builder.cursorSet) throw new IllegalArgumentException("cursor is required");
        this.cursor = builder.cursor;
        if (!builder.fgSet) throw new IllegalArgumentException("fg is required");
        this.fg = builder.fg;
    }

    public static Builder builder() { return new Builder(); }

    public String bg() { return bg; }
    public String cursor() { return cursor; }
    public String fg() { return fg; }

    public static TerminalColorOverrides fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalColorOverrides");
        Builder builder = builder();
        Object rawBg = Wire.required(object, "bg");
        builder.bg(rawBg == null ? null : Wire.string(rawBg, "TerminalColorOverrides.bg"));
        Object rawCursor = Wire.required(object, "cursor");
        builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "TerminalColorOverrides.cursor"));
        Object rawFg = Wire.required(object, "fg");
        builder.fg(rawFg == null ? null : Wire.string(rawFg, "TerminalColorOverrides.fg"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bg", bg);
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "fg", fg);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalColorOverrides that)) return false;
        return Objects.equals(bg, that.bg) && Objects.equals(cursor, that.cursor) && Objects.equals(fg, that.fg);
    }

    @Override
    public int hashCode() { return Objects.hash(bg, cursor, fg); }

    @Override
    public String toString() { return "TerminalColorOverrides" + toWire(); }

    public static final class Builder {
        private String bg;
        private boolean bgSet;
        private String cursor;
        private boolean cursorSet;
        private String fg;
        private boolean fgSet;

        public Builder bg(String value) {
            this.bg = value;
            this.bgSet = true;
            return this;
        }
        public Builder cursor(String value) {
            this.cursor = value;
            this.cursorSet = true;
            return this;
        }
        public Builder fg(String value) {
            this.fg = value;
            this.fgSet = true;
            return this;
        }
        public TerminalColorOverrides build() { return new TerminalColorOverrides(this); }
    }
}
