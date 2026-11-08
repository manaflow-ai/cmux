// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderGraphicImage implements WireValue {
    private final Bytes data;
    private final RenderGraphicFormat format;
    private final UInt64 generation;
    private final long height;
    private final long id;
    private final long width;

    private RenderGraphicImage(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.formatSet) throw new IllegalArgumentException("format is required");
        this.format = Wire.nonNull(builder.format, "format");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.heightSet) throw new IllegalArgumentException("height is required");
        this.height = builder.height;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = builder.id;
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Bytes data() { return data; }
    public RenderGraphicFormat format() { return format; }
    public UInt64 generation() { return generation; }
    public long height() { return height; }
    public long id() { return id; }
    public long width() { return width; }

    public static RenderGraphicImage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderGraphicImage");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "RenderGraphicImage.data"));
        Object rawFormat = Wire.required(object, "format");
        builder.format(RenderGraphicFormat.fromWire(rawFormat));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "RenderGraphicImage.generation"));
        Object rawHeight = Wire.required(object, "height");
        builder.height(Wire.uint32(rawHeight, "RenderGraphicImage.height"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint32(rawId, "RenderGraphicImage.id"));
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.uint32(rawWidth, "RenderGraphicImage.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "format", format);
        Wire.put(object, "generation", generation);
        Wire.put(object, "height", height);
        Wire.put(object, "id", id);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderGraphicImage that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(format, that.format) && Objects.equals(generation, that.generation) && Objects.equals(height, that.height) && Objects.equals(id, that.id) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(data, format, generation, height, id, width); }

    @Override
    public String toString() { return "RenderGraphicImage" + toWire(); }

    public static final class Builder {
        private Bytes data;
        private boolean dataSet;
        private RenderGraphicFormat format;
        private boolean formatSet;
        private UInt64 generation;
        private boolean generationSet;
        private Long height;
        private boolean heightSet;
        private Long id;
        private boolean idSet;
        private Long width;
        private boolean widthSet;

        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder format(RenderGraphicFormat value) {
            this.format = value;
            this.formatSet = true;
            return this;
        }
        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder height(long value) {
            this.height = value;
            this.heightSet = true;
            return this;
        }
        public Builder id(long value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder width(long value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public RenderGraphicImage build() { return new RenderGraphicImage(this); }
    }
}
