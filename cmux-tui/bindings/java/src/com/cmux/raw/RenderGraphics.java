// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderGraphics implements WireValue {
    private final UInt64 generation;
    private final Field<List<RenderGraphicImage>> images;
    private final List<RenderGraphicPlacement> placements;
    private final Field<List<Long>> removedImageIds;

    private RenderGraphics(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        this.images = builder.images.map(value -> List.copyOf(value));
        if (!builder.placementsSet) throw new IllegalArgumentException("placements is required");
        this.placements = List.copyOf(Wire.nonNull(builder.placements, "placements"));
        this.removedImageIds = builder.removedImageIds.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 generation() { return generation; }
    public Field<List<RenderGraphicImage>> images() { return images; }
    public List<RenderGraphicPlacement> placements() { return placements; }
    public Field<List<Long>> removedImageIds() { return removedImageIds; }

    public static RenderGraphics fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderGraphics");
        Builder builder = builder();
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "RenderGraphics.generation"));
        Object rawImages = Wire.optional(object, "images");
        if (!Wire.isMissing(rawImages)) {
            builder.images(Wire.array(rawImages, "RenderGraphics.images", item -> RenderGraphicImage.fromWire(item)));
        }
        Object rawPlacements = Wire.required(object, "placements");
        builder.placements(Wire.array(rawPlacements, "RenderGraphics.placements", item -> RenderGraphicPlacement.fromWire(item)));
        Object rawRemovedImageIds = Wire.optional(object, "removed_image_ids");
        if (!Wire.isMissing(rawRemovedImageIds)) {
            builder.removedImageIds(Wire.array(rawRemovedImageIds, "RenderGraphics.removed_image_ids", item -> Wire.uint32(item, "RenderGraphics.removed_image_ids item")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "generation", generation);
        Wire.put(object, "images", images);
        Wire.put(object, "placements", placements);
        Wire.put(object, "removed_image_ids", removedImageIds);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderGraphics that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(images, that.images) && Objects.equals(placements, that.placements) && Objects.equals(removedImageIds, that.removedImageIds);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, images, placements, removedImageIds); }

    @Override
    public String toString() { return "RenderGraphics" + toWire(); }

    public static final class Builder {
        private UInt64 generation;
        private boolean generationSet;
        private Field<List<RenderGraphicImage>> images = Field.omitted();
        private List<RenderGraphicPlacement> placements;
        private boolean placementsSet;
        private Field<List<Long>> removedImageIds = Field.omitted();

        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder images(List<RenderGraphicImage> value) {
            this.images = Field.of(value);
            return this;
        }
        public Builder placements(List<RenderGraphicPlacement> value) {
            this.placements = value;
            this.placementsSet = true;
            return this;
        }
        public Builder removedImageIds(List<Long> value) {
            this.removedImageIds = Field.of(value);
            return this;
        }
        public RenderGraphics build() { return new RenderGraphics(this); }
    }
}
