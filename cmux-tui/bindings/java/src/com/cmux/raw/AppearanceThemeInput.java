// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceThemeInput implements WireValue {
    private final Field<String> accentColor;
    private final String background;
    private final int backgroundBlur;
    private final double backgroundOpacity;
    private final Field<String> cursor;
    private final String foreground;
    private final List<String> palette;
    private final Field<String> selectionBackground;
    private final Field<String> selectionForeground;

    private AppearanceThemeInput(Builder builder) {
        this.accentColor = builder.accentColor;
        if (!builder.backgroundSet) throw new IllegalArgumentException("background is required");
        this.background = Wire.nonNull(builder.background, "background");
        if (!builder.backgroundBlurSet) throw new IllegalArgumentException("background_blur is required");
        this.backgroundBlur = builder.backgroundBlur;
        if (!builder.backgroundOpacitySet) throw new IllegalArgumentException("background_opacity is required");
        this.backgroundOpacity = builder.backgroundOpacity;
        this.cursor = builder.cursor;
        if (!builder.foregroundSet) throw new IllegalArgumentException("foreground is required");
        this.foreground = Wire.nonNull(builder.foreground, "foreground");
        if (!builder.paletteSet) throw new IllegalArgumentException("palette is required");
        this.palette = List.copyOf(Wire.nonNull(builder.palette, "palette"));
        this.selectionBackground = builder.selectionBackground;
        this.selectionForeground = builder.selectionForeground;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> accentColor() { return accentColor; }
    public String background() { return background; }
    public int backgroundBlur() { return backgroundBlur; }
    public double backgroundOpacity() { return backgroundOpacity; }
    public Field<String> cursor() { return cursor; }
    public String foreground() { return foreground; }
    public List<String> palette() { return palette; }
    public Field<String> selectionBackground() { return selectionBackground; }
    public Field<String> selectionForeground() { return selectionForeground; }

    public static AppearanceThemeInput fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceThemeInput");
        Builder builder = builder();
        Object rawAccentColor = Wire.optional(object, "accent_color");
        if (!Wire.isMissing(rawAccentColor)) {
            builder.accentColor(rawAccentColor == null ? null : Wire.string(rawAccentColor, "AppearanceThemeInput.accent_color"));
        }
        Object rawBackground = Wire.required(object, "background");
        builder.background(Wire.string(rawBackground, "AppearanceThemeInput.background"));
        Object rawBackgroundBlur = Wire.required(object, "background_blur");
        builder.backgroundBlur(Wire.int32(rawBackgroundBlur, "AppearanceThemeInput.background_blur"));
        Object rawBackgroundOpacity = Wire.required(object, "background_opacity");
        builder.backgroundOpacity(Wire.float64(rawBackgroundOpacity, "AppearanceThemeInput.background_opacity"));
        Object rawCursor = Wire.optional(object, "cursor");
        if (!Wire.isMissing(rawCursor)) {
            builder.cursor(rawCursor == null ? null : Wire.string(rawCursor, "AppearanceThemeInput.cursor"));
        }
        Object rawForeground = Wire.required(object, "foreground");
        builder.foreground(Wire.string(rawForeground, "AppearanceThemeInput.foreground"));
        Object rawPalette = Wire.required(object, "palette");
        builder.palette(Wire.array(rawPalette, "AppearanceThemeInput.palette", item -> Wire.string(item, "AppearanceThemeInput.palette item")));
        Object rawSelectionBackground = Wire.optional(object, "selection_background");
        if (!Wire.isMissing(rawSelectionBackground)) {
            builder.selectionBackground(rawSelectionBackground == null ? null : Wire.string(rawSelectionBackground, "AppearanceThemeInput.selection_background"));
        }
        Object rawSelectionForeground = Wire.optional(object, "selection_foreground");
        if (!Wire.isMissing(rawSelectionForeground)) {
            builder.selectionForeground(rawSelectionForeground == null ? null : Wire.string(rawSelectionForeground, "AppearanceThemeInput.selection_foreground"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accent_color", accentColor);
        Wire.put(object, "background", background);
        Wire.put(object, "background_blur", backgroundBlur);
        Wire.put(object, "background_opacity", backgroundOpacity);
        Wire.put(object, "cursor", cursor);
        Wire.put(object, "foreground", foreground);
        Wire.put(object, "palette", palette);
        Wire.put(object, "selection_background", selectionBackground);
        Wire.put(object, "selection_foreground", selectionForeground);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceThemeInput that)) return false;
        return Objects.equals(accentColor, that.accentColor) && Objects.equals(background, that.background) && Objects.equals(backgroundBlur, that.backgroundBlur) && Objects.equals(backgroundOpacity, that.backgroundOpacity) && Objects.equals(cursor, that.cursor) && Objects.equals(foreground, that.foreground) && Objects.equals(palette, that.palette) && Objects.equals(selectionBackground, that.selectionBackground) && Objects.equals(selectionForeground, that.selectionForeground);
    }

    @Override
    public int hashCode() { return Objects.hash(accentColor, background, backgroundBlur, backgroundOpacity, cursor, foreground, palette, selectionBackground, selectionForeground); }

    @Override
    public String toString() { return "AppearanceThemeInput" + toWire(); }

    public static final class Builder {
        private Field<String> accentColor = Field.omitted();
        private String background;
        private boolean backgroundSet;
        private Integer backgroundBlur;
        private boolean backgroundBlurSet;
        private Double backgroundOpacity;
        private boolean backgroundOpacitySet;
        private Field<String> cursor = Field.omitted();
        private String foreground;
        private boolean foregroundSet;
        private List<String> palette;
        private boolean paletteSet;
        private Field<String> selectionBackground = Field.omitted();
        private Field<String> selectionForeground = Field.omitted();

        public Builder accentColor(String value) {
            this.accentColor = Field.ofNullable(value);
            return this;
        }
        public Builder background(String value) {
            this.background = value;
            this.backgroundSet = true;
            return this;
        }
        public Builder backgroundBlur(int value) {
            this.backgroundBlur = value;
            this.backgroundBlurSet = true;
            return this;
        }
        public Builder backgroundOpacity(double value) {
            this.backgroundOpacity = value;
            this.backgroundOpacitySet = true;
            return this;
        }
        public Builder cursor(String value) {
            this.cursor = Field.ofNullable(value);
            return this;
        }
        public Builder foreground(String value) {
            this.foreground = value;
            this.foregroundSet = true;
            return this;
        }
        public Builder palette(List<String> value) {
            this.palette = value;
            this.paletteSet = true;
            return this;
        }
        public Builder selectionBackground(String value) {
            this.selectionBackground = Field.ofNullable(value);
            return this;
        }
        public Builder selectionForeground(String value) {
            this.selectionForeground = Field.ofNullable(value);
            return this;
        }
        public AppearanceThemeInput build() { return new AppearanceThemeInput(this); }
    }
}
