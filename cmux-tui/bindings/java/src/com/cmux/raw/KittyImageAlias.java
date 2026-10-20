// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class KittyImageAlias implements WireValue {
    private final long imageId;
    private final long imageNumber;

    private KittyImageAlias(Builder builder) {
        if (!builder.imageIdSet) throw new IllegalArgumentException("image_id is required");
        this.imageId = builder.imageId;
        if (!builder.imageNumberSet) throw new IllegalArgumentException("image_number is required");
        this.imageNumber = builder.imageNumber;
    }

    public static Builder builder() { return new Builder(); }

    public long imageId() { return imageId; }
    public long imageNumber() { return imageNumber; }

    public static KittyImageAlias fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "KittyImageAlias");
        Builder builder = builder();
        Object rawImageId = Wire.required(object, "image_id");
        builder.imageId(Wire.uint32(rawImageId, "KittyImageAlias.image_id"));
        Object rawImageNumber = Wire.required(object, "image_number");
        builder.imageNumber(Wire.uint32(rawImageNumber, "KittyImageAlias.image_number"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "image_id", imageId);
        Wire.put(object, "image_number", imageNumber);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof KittyImageAlias that)) return false;
        return Objects.equals(imageId, that.imageId) && Objects.equals(imageNumber, that.imageNumber);
    }

    @Override
    public int hashCode() { return Objects.hash(imageId, imageNumber); }

    @Override
    public String toString() { return "KittyImageAlias" + toWire(); }

    public static final class Builder {
        private Long imageId;
        private boolean imageIdSet;
        private Long imageNumber;
        private boolean imageNumberSet;

        public Builder imageId(long value) {
            this.imageId = value;
            this.imageIdSet = true;
            return this;
        }
        public Builder imageNumber(long value) {
            this.imageNumber = value;
            this.imageNumberSet = true;
            return this;
        }
        public KittyImageAlias build() { return new KittyImageAlias(this); }
    }
}
