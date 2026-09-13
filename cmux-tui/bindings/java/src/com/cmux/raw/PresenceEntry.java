// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PresenceEntry implements WireValue {
    private final UInt64 client;
    private final UInt64 color;
    private final UInt64 generation;
    private final PresenceHighlight highlight;
    private final String kind;
    private final String name;
    private final PresenceAnchor pointer;
    private final UInt64 surface;
    private final UInt64 updatedAtMs;

    private PresenceEntry(Builder builder) {
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.colorSet) throw new IllegalArgumentException("color is required");
        this.color = Wire.nonNull(builder.color, "color");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.highlightSet) throw new IllegalArgumentException("highlight is required");
        this.highlight = builder.highlight;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = builder.kind;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.pointerSet) throw new IllegalArgumentException("pointer is required");
        this.pointer = builder.pointer;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
        if (!builder.updatedAtMsSet) throw new IllegalArgumentException("updated_at_ms is required");
        this.updatedAtMs = Wire.nonNull(builder.updatedAtMs, "updated_at_ms");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 client() { return client; }
    public UInt64 color() { return color; }
    public UInt64 generation() { return generation; }
    public PresenceHighlight highlight() { return highlight; }
    public String kind() { return kind; }
    public String name() { return name; }
    public PresenceAnchor pointer() { return pointer; }
    public UInt64 surface() { return surface; }
    public UInt64 updatedAtMs() { return updatedAtMs; }

    public static PresenceEntry fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceEntry");
        Builder builder = builder();
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "PresenceEntry.client"));
        Object rawColor = Wire.required(object, "color");
        builder.color(Wire.uint64(rawColor, "PresenceEntry.color"));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "PresenceEntry.generation"));
        Object rawHighlight = Wire.required(object, "highlight");
        builder.highlight(rawHighlight == null ? null : PresenceHighlight.fromWire(rawHighlight));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(rawKind == null ? null : Wire.string(rawKind, "PresenceEntry.kind"));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "PresenceEntry.name"));
        Object rawPointer = Wire.required(object, "pointer");
        builder.pointer(rawPointer == null ? null : PresenceAnchor.fromWire(rawPointer));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "PresenceEntry.surface"));
        Object rawUpdatedAtMs = Wire.required(object, "updated_at_ms");
        builder.updatedAtMs(Wire.uint64(rawUpdatedAtMs, "PresenceEntry.updated_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client", client);
        Wire.put(object, "color", color);
        Wire.put(object, "generation", generation);
        Wire.put(object, "highlight", highlight);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "pointer", pointer);
        Wire.put(object, "surface", surface);
        Wire.put(object, "updated_at_ms", updatedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceEntry that)) return false;
        return Objects.equals(client, that.client) && Objects.equals(color, that.color) && Objects.equals(generation, that.generation) && Objects.equals(highlight, that.highlight) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(pointer, that.pointer) && Objects.equals(surface, that.surface) && Objects.equals(updatedAtMs, that.updatedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(client, color, generation, highlight, kind, name, pointer, surface, updatedAtMs); }

    @Override
    public String toString() { return "PresenceEntry" + toWire(); }

    public static final class Builder {
        private UInt64 client;
        private boolean clientSet;
        private UInt64 color;
        private boolean colorSet;
        private UInt64 generation;
        private boolean generationSet;
        private PresenceHighlight highlight;
        private boolean highlightSet;
        private String kind;
        private boolean kindSet;
        private String name;
        private boolean nameSet;
        private PresenceAnchor pointer;
        private boolean pointerSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private UInt64 updatedAtMs;
        private boolean updatedAtMsSet;

        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder color(UInt64 value) {
            this.color = value;
            this.colorSet = true;
            return this;
        }
        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder highlight(PresenceHighlight value) {
            this.highlight = value;
            this.highlightSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder pointer(PresenceAnchor value) {
            this.pointer = value;
            this.pointerSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder updatedAtMs(UInt64 value) {
            this.updatedAtMs = value;
            this.updatedAtMsSet = true;
            return this;
        }
        public PresenceEntry build() { return new PresenceEntry(this); }
    }
}
