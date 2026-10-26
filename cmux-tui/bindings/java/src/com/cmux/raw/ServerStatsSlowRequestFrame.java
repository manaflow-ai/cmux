// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsSlowRequestFrame implements WireValue {
    private final String image;
    private final String imageId;
    private final UInt64 offset;
    private final String symbol;

    private ServerStatsSlowRequestFrame(Builder builder) {
        if (!builder.imageSet) throw new IllegalArgumentException("image is required");
        this.image = builder.image;
        if (!builder.imageIdSet) throw new IllegalArgumentException("image_id is required");
        this.imageId = builder.imageId;
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.symbolSet) throw new IllegalArgumentException("symbol is required");
        this.symbol = builder.symbol;
    }

    public static Builder builder() { return new Builder(); }

    public String image() { return image; }
    public String imageId() { return imageId; }
    public UInt64 offset() { return offset; }
    public String symbol() { return symbol; }

    public static ServerStatsSlowRequestFrame fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsSlowRequestFrame");
        Builder builder = builder();
        Object rawImage = Wire.required(object, "image");
        builder.image(rawImage == null ? null : Wire.string(rawImage, "ServerStatsSlowRequestFrame.image"));
        Object rawImageId = Wire.required(object, "image_id");
        builder.imageId(rawImageId == null ? null : Wire.string(rawImageId, "ServerStatsSlowRequestFrame.image_id"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "ServerStatsSlowRequestFrame.offset"));
        Object rawSymbol = Wire.required(object, "symbol");
        builder.symbol(rawSymbol == null ? null : Wire.string(rawSymbol, "ServerStatsSlowRequestFrame.symbol"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "image", image);
        Wire.put(object, "image_id", imageId);
        Wire.put(object, "offset", offset);
        Wire.put(object, "symbol", symbol);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsSlowRequestFrame that)) return false;
        return Objects.equals(image, that.image) && Objects.equals(imageId, that.imageId) && Objects.equals(offset, that.offset) && Objects.equals(symbol, that.symbol);
    }

    @Override
    public int hashCode() { return Objects.hash(image, imageId, offset, symbol); }

    @Override
    public String toString() { return "ServerStatsSlowRequestFrame" + toWire(); }

    public static final class Builder {
        private String image;
        private boolean imageSet;
        private String imageId;
        private boolean imageIdSet;
        private UInt64 offset;
        private boolean offsetSet;
        private String symbol;
        private boolean symbolSet;

        public Builder image(String value) {
            this.image = value;
            this.imageSet = true;
            return this;
        }
        public Builder imageId(String value) {
            this.imageId = value;
            this.imageIdSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder symbol(String value) {
            this.symbol = value;
            this.symbolSet = true;
            return this;
        }
        public ServerStatsSlowRequestFrame build() { return new ServerStatsSlowRequestFrame(this); }
    }
}
