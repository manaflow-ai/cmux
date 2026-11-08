// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class KittyGraphicsState implements WireValue {
    private final long alternateNextImageId;
    private final long alternateReplayNextImageId;
    private final UInt64 imageBytes;
    private final UInt64 images;
    private final UInt64 inflightBytes;
    private final UInt64 placements;
    private final long primaryNextImageId;
    private final long primaryReplayNextImageId;
    private final long replayCursorOffset;

    private KittyGraphicsState(Builder builder) {
        if (!builder.alternateNextImageIdSet) throw new IllegalArgumentException("alternate_next_image_id is required");
        this.alternateNextImageId = builder.alternateNextImageId;
        if (!builder.alternateReplayNextImageIdSet) throw new IllegalArgumentException("alternate_replay_next_image_id is required");
        this.alternateReplayNextImageId = builder.alternateReplayNextImageId;
        if (!builder.imageBytesSet) throw new IllegalArgumentException("image_bytes is required");
        this.imageBytes = Wire.nonNull(builder.imageBytes, "image_bytes");
        if (!builder.imagesSet) throw new IllegalArgumentException("images is required");
        this.images = Wire.nonNull(builder.images, "images");
        if (!builder.inflightBytesSet) throw new IllegalArgumentException("inflight_bytes is required");
        this.inflightBytes = Wire.nonNull(builder.inflightBytes, "inflight_bytes");
        if (!builder.placementsSet) throw new IllegalArgumentException("placements is required");
        this.placements = Wire.nonNull(builder.placements, "placements");
        if (!builder.primaryNextImageIdSet) throw new IllegalArgumentException("primary_next_image_id is required");
        this.primaryNextImageId = builder.primaryNextImageId;
        if (!builder.primaryReplayNextImageIdSet) throw new IllegalArgumentException("primary_replay_next_image_id is required");
        this.primaryReplayNextImageId = builder.primaryReplayNextImageId;
        if (!builder.replayCursorOffsetSet) throw new IllegalArgumentException("replay_cursor_offset is required");
        this.replayCursorOffset = builder.replayCursorOffset;
    }

    public static Builder builder() { return new Builder(); }

    public long alternateNextImageId() { return alternateNextImageId; }
    public long alternateReplayNextImageId() { return alternateReplayNextImageId; }
    public UInt64 imageBytes() { return imageBytes; }
    public UInt64 images() { return images; }
    public UInt64 inflightBytes() { return inflightBytes; }
    public UInt64 placements() { return placements; }
    public long primaryNextImageId() { return primaryNextImageId; }
    public long primaryReplayNextImageId() { return primaryReplayNextImageId; }
    public long replayCursorOffset() { return replayCursorOffset; }

    public static KittyGraphicsState fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "KittyGraphicsState");
        Builder builder = builder();
        Object rawAlternateNextImageId = Wire.required(object, "alternate_next_image_id");
        builder.alternateNextImageId(Wire.uint32(rawAlternateNextImageId, "KittyGraphicsState.alternate_next_image_id"));
        Object rawAlternateReplayNextImageId = Wire.required(object, "alternate_replay_next_image_id");
        builder.alternateReplayNextImageId(Wire.uint32(rawAlternateReplayNextImageId, "KittyGraphicsState.alternate_replay_next_image_id"));
        Object rawImageBytes = Wire.required(object, "image_bytes");
        builder.imageBytes(Wire.uint64(rawImageBytes, "KittyGraphicsState.image_bytes"));
        Object rawImages = Wire.required(object, "images");
        builder.images(Wire.uint64(rawImages, "KittyGraphicsState.images"));
        Object rawInflightBytes = Wire.required(object, "inflight_bytes");
        builder.inflightBytes(Wire.uint64(rawInflightBytes, "KittyGraphicsState.inflight_bytes"));
        Object rawPlacements = Wire.required(object, "placements");
        builder.placements(Wire.uint64(rawPlacements, "KittyGraphicsState.placements"));
        Object rawPrimaryNextImageId = Wire.required(object, "primary_next_image_id");
        builder.primaryNextImageId(Wire.uint32(rawPrimaryNextImageId, "KittyGraphicsState.primary_next_image_id"));
        Object rawPrimaryReplayNextImageId = Wire.required(object, "primary_replay_next_image_id");
        builder.primaryReplayNextImageId(Wire.uint32(rawPrimaryReplayNextImageId, "KittyGraphicsState.primary_replay_next_image_id"));
        Object rawReplayCursorOffset = Wire.required(object, "replay_cursor_offset");
        builder.replayCursorOffset(Wire.uint32(rawReplayCursorOffset, "KittyGraphicsState.replay_cursor_offset"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "alternate_next_image_id", alternateNextImageId);
        Wire.put(object, "alternate_replay_next_image_id", alternateReplayNextImageId);
        Wire.put(object, "image_bytes", imageBytes);
        Wire.put(object, "images", images);
        Wire.put(object, "inflight_bytes", inflightBytes);
        Wire.put(object, "placements", placements);
        Wire.put(object, "primary_next_image_id", primaryNextImageId);
        Wire.put(object, "primary_replay_next_image_id", primaryReplayNextImageId);
        Wire.put(object, "replay_cursor_offset", replayCursorOffset);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof KittyGraphicsState that)) return false;
        return Objects.equals(alternateNextImageId, that.alternateNextImageId) && Objects.equals(alternateReplayNextImageId, that.alternateReplayNextImageId) && Objects.equals(imageBytes, that.imageBytes) && Objects.equals(images, that.images) && Objects.equals(inflightBytes, that.inflightBytes) && Objects.equals(placements, that.placements) && Objects.equals(primaryNextImageId, that.primaryNextImageId) && Objects.equals(primaryReplayNextImageId, that.primaryReplayNextImageId) && Objects.equals(replayCursorOffset, that.replayCursorOffset);
    }

    @Override
    public int hashCode() { return Objects.hash(alternateNextImageId, alternateReplayNextImageId, imageBytes, images, inflightBytes, placements, primaryNextImageId, primaryReplayNextImageId, replayCursorOffset); }

    @Override
    public String toString() { return "KittyGraphicsState" + toWire(); }

    public static final class Builder {
        private Long alternateNextImageId;
        private boolean alternateNextImageIdSet;
        private Long alternateReplayNextImageId;
        private boolean alternateReplayNextImageIdSet;
        private UInt64 imageBytes;
        private boolean imageBytesSet;
        private UInt64 images;
        private boolean imagesSet;
        private UInt64 inflightBytes;
        private boolean inflightBytesSet;
        private UInt64 placements;
        private boolean placementsSet;
        private Long primaryNextImageId;
        private boolean primaryNextImageIdSet;
        private Long primaryReplayNextImageId;
        private boolean primaryReplayNextImageIdSet;
        private Long replayCursorOffset;
        private boolean replayCursorOffsetSet;

        public Builder alternateNextImageId(long value) {
            this.alternateNextImageId = value;
            this.alternateNextImageIdSet = true;
            return this;
        }
        public Builder alternateReplayNextImageId(long value) {
            this.alternateReplayNextImageId = value;
            this.alternateReplayNextImageIdSet = true;
            return this;
        }
        public Builder imageBytes(UInt64 value) {
            this.imageBytes = value;
            this.imageBytesSet = true;
            return this;
        }
        public Builder images(UInt64 value) {
            this.images = value;
            this.imagesSet = true;
            return this;
        }
        public Builder inflightBytes(UInt64 value) {
            this.inflightBytes = value;
            this.inflightBytesSet = true;
            return this;
        }
        public Builder placements(UInt64 value) {
            this.placements = value;
            this.placementsSet = true;
            return this;
        }
        public Builder primaryNextImageId(long value) {
            this.primaryNextImageId = value;
            this.primaryNextImageIdSet = true;
            return this;
        }
        public Builder primaryReplayNextImageId(long value) {
            this.primaryReplayNextImageId = value;
            this.primaryReplayNextImageIdSet = true;
            return this;
        }
        public Builder replayCursorOffset(long value) {
            this.replayCursorOffset = value;
            this.replayCursorOffsetSet = true;
            return this;
        }
        public KittyGraphicsState build() { return new KittyGraphicsState(this); }
    }
}
