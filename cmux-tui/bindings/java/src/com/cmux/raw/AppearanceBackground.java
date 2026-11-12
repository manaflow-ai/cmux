// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceBackground implements WireValue {
    private final Object blur;
    private final UInt64 bytes;
    private final long height;
    private final double luminance;
    private final Object opacity;
    private final Field<String> path;
    private final String sha256;
    private final long width;

    private AppearanceBackground(Builder builder) {
        if (!builder.blurSet) throw new IllegalArgumentException("blur is required");
        this.blur = builder.blur == null ? null : Wire.immutableJson(builder.blur);
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = builder.height;
        if (!builder.luminanceSet) throw new IllegalArgumentException("luminance is required");
        this.luminance = builder.luminance;
        if (!builder.opacitySet) throw new IllegalArgumentException("opacity is required");
        this.opacity = builder.opacity == null ? null : Wire.immutableJson(builder.opacity);
        this.path = builder.path;
        if (!builder.sha256Set) throw new IllegalArgumentException("sha256 is required");
        this.sha256 = Wire.nonNull(builder.sha256, "sha256");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Object blur() { return blur; }
    public UInt64 bytes() { return bytes; }
    public long height() { return height; }
    public double luminance() { return luminance; }
    public Object opacity() { return opacity; }
    public Field<String> path() { return path; }
    public String sha256() { return sha256; }
    public long width() { return width; }

    public static AppearanceBackground fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceBackground");
        Builder builder = builder();
        Object rawBlur = Wire.required(object, "blur");
        builder.blur(rawBlur == null ? null : Wire.immutableJson(rawBlur));
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "AppearanceBackground.bytes"));
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint32(rawHeight, "AppearanceBackground.height"));
        Object rawLuminance = Wire.required(object, "luminance");
        builder.luminance(Wire.float64(rawLuminance, "AppearanceBackground.luminance"));
        Object rawOpacity = Wire.required(object, "opacity");
        builder.opacity(rawOpacity == null ? null : Wire.immutableJson(rawOpacity));
        Object rawPath = Wire.optional(object, "path");
        if (!Wire.isMissing(rawPath)) {
            builder.path(rawPath == null ? null : Wire.string(rawPath, "AppearanceBackground.path"));
        }
        Object rawSha256 = Wire.required(object, "sha256");
        builder.sha256(Wire.string(rawSha256, "AppearanceBackground.sha256"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.uint32(rawWidth, "AppearanceBackground.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "blur", blur);
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "height", height);
        Wire.put(object, "luminance", luminance);
        Wire.put(object, "opacity", opacity);
        Wire.put(object, "path", path);
        Wire.put(object, "sha256", sha256);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceBackground that)) return false;
        return Objects.equals(blur, that.blur) && Objects.equals(bytes, that.bytes) && Objects.equals(height, that.height) && Objects.equals(luminance, that.luminance) && Objects.equals(opacity, that.opacity) && Objects.equals(path, that.path) && Objects.equals(sha256, that.sha256) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(blur, bytes, height, luminance, opacity, path, sha256, width); }

    @Override
    public String toString() { return "AppearanceBackground" + toWire(); }

    public static final class Builder {
        private Object blur;
        private boolean blurSet;
        private UInt64 bytes;
        private boolean bytesSet;
        private Long height;
        private boolean heightSet;
        private Double luminance;
        private boolean luminanceSet;
        private Object opacity;
        private boolean opacitySet;
        private Field<String> path = Field.omitted();
        private String sha256;
        private boolean sha256Set;
        private Long width;
        private boolean widthSet;

        public Builder blur(Object value) {
            this.blur = value;
            this.blurSet = true;
            return this;
        }
        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder height(long value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
        public Builder luminance(double value) {
            this.luminance = value;
            this.luminanceSet = true;
            return this;
        }
        public Builder opacity(Object value) {
            this.opacity = value;
            this.opacitySet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = Field.ofNullable(value);
            return this;
        }
        public Builder sha256(String value) {
            this.sha256 = value;
            this.sha256Set = true;
            return this;
        }
        public Builder width(long value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public AppearanceBackground build() { return new AppearanceBackground(this); }
    }
}
