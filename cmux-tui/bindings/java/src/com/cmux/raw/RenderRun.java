// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderRun implements WireValue {
    private final long attrs;
    private final String bg;
    private final String fg;
    private final String text;
    private final Field<RenderUnderline> underline;
    private final Field<Integer> widthHint;

    private RenderRun(Builder builder) {
        if (!builder.attrsSet) throw new IllegalArgumentException("attrs is required");
        this.attrs = builder.attrs;
        if (!builder.bgSet) throw new IllegalArgumentException("bg is required");
        this.bg = builder.bg;
        if (!builder.fgSet) throw new IllegalArgumentException("fg is required");
        this.fg = builder.fg;
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
        this.underline = builder.underline;
        this.widthHint = builder.widthHint;
    }

    public static Builder builder() { return new Builder(); }

    public long attrs() { return attrs; }
    public String bg() { return bg; }
    public String fg() { return fg; }
    public String text() { return text; }
    public Field<RenderUnderline> underline() { return underline; }
    public Field<Integer> widthHint() { return widthHint; }

    public static RenderRun fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderRun");
        Builder builder = builder();
        Object rawAttrs = Wire.required(object, "attrs");
        builder.attrs(Wire.uint32(rawAttrs, "RenderRun.attrs"));
        Object rawBg = Wire.required(object, "bg");
        builder.bg(rawBg == null ? null : Wire.string(rawBg, "RenderRun.bg"));
        Object rawFg = Wire.required(object, "fg");
        builder.fg(rawFg == null ? null : Wire.string(rawFg, "RenderRun.fg"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "RenderRun.text"));
        Object rawUnderline = Wire.optional(object, "underline");
        if (!Wire.isMissing(rawUnderline)) {
            builder.underline(RenderUnderline.fromWire(rawUnderline));
        }
        Object rawWidthHint = Wire.optional(object, "width_hint");
        if (!Wire.isMissing(rawWidthHint)) {
            builder.widthHint(Wire.uint16(rawWidthHint, "RenderRun.width_hint"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "attrs", attrs);
        Wire.put(object, "bg", bg);
        Wire.put(object, "fg", fg);
        Wire.put(object, "text", text);
        Wire.put(object, "underline", underline);
        Wire.put(object, "width_hint", widthHint);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderRun that)) return false;
        return Objects.equals(attrs, that.attrs) && Objects.equals(bg, that.bg) && Objects.equals(fg, that.fg) && Objects.equals(text, that.text) && Objects.equals(underline, that.underline) && Objects.equals(widthHint, that.widthHint);
    }

    @Override
    public int hashCode() { return Objects.hash(attrs, bg, fg, text, underline, widthHint); }

    @Override
    public String toString() { return "RenderRun" + toWire(); }

    public static final class Builder {
        private Long attrs;
        private boolean attrsSet;
        private String bg;
        private boolean bgSet;
        private String fg;
        private boolean fgSet;
        private String text;
        private boolean textSet;
        private Field<RenderUnderline> underline = Field.omitted();
        private Field<Integer> widthHint = Field.omitted();

        public Builder attrs(long value) {
            this.attrs = value;
            this.attrsSet = true;
            return this;
        }
        public Builder bg(String value) {
            this.bg = value;
            this.bgSet = true;
            return this;
        }
        public Builder fg(String value) {
            this.fg = value;
            this.fgSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public Builder underline(RenderUnderline value) {
            this.underline = Field.of(value);
            return this;
        }
        public Builder widthHint(Integer value) {
            this.widthHint = Field.of(value);
            return this;
        }
        public RenderRun build() { return new RenderRun(this); }
    }
}
