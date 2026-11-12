// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceBackgroundRequest implements WireValue {
    private final long height;
    private final double luminance;
    private final String path;
    private final String sha256;
    private final long width;

    private AppearanceBackgroundRequest(Builder builder) {
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = builder.height;
        if (!builder.luminanceSet) throw new IllegalArgumentException("luminance is required");
        this.luminance = builder.luminance;
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        if (!builder.sha256Set) throw new IllegalArgumentException("sha256 is required");
        this.sha256 = Wire.nonNull(builder.sha256, "sha256");
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public long height() { return height; }
    public double luminance() { return luminance; }
    public String path() { return path; }
    public String sha256() { return sha256; }
    public long width() { return width; }

    public static AppearanceBackgroundRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceBackgroundRequest");
        Builder builder = builder();
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint32(rawHeight, "AppearanceBackgroundRequest.height"));
        Object rawLuminance = Wire.required(object, "luminance");
        builder.luminance(Wire.float64(rawLuminance, "AppearanceBackgroundRequest.luminance"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "AppearanceBackgroundRequest.path"));
        Object rawSha256 = Wire.required(object, "sha256");
        builder.sha256(Wire.string(rawSha256, "AppearanceBackgroundRequest.sha256"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.uint32(rawWidth, "AppearanceBackgroundRequest.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "height", height);
        Wire.put(object, "luminance", luminance);
        Wire.put(object, "path", path);
        Wire.put(object, "sha256", sha256);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceBackgroundRequest that)) return false;
        return Objects.equals(height, that.height) && Objects.equals(luminance, that.luminance) && Objects.equals(path, that.path) && Objects.equals(sha256, that.sha256) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(height, luminance, path, sha256, width); }

    @Override
    public String toString() { return "AppearanceBackgroundRequest" + toWire(); }

    public static final class Builder {
        private Long height;
        private boolean heightSet;
        private Double luminance;
        private boolean luminanceSet;
        private String path;
        private boolean pathSet;
        private String sha256;
        private boolean sha256Set;
        private Long width;
        private boolean widthSet;

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
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
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
        public AppearanceBackgroundRequest build() { return new AppearanceBackgroundRequest(this); }
    }
}
