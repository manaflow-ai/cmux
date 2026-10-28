// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable digest event. Protocol v12; streams: attach-byte. */
public final class DigestEvent implements WireValue, ByteAttachEvent, ProtocolEvent {
    private final UInt64 generation;
    private final UInt64 offset;
    /** Lowercase hex SHA-256 (64 characters) of the host's READY encoding. */
    private final String sha256;
    private final UInt64 surface;
    private final int version;

    private DigestEvent(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.offsetSet) throw new IllegalArgumentException("offset is required");
        this.offset = Wire.nonNull(builder.offset, "offset");
        if (!builder.sha256Set) throw new IllegalArgumentException("sha256 is required");
        this.sha256 = Wire.nonNull(builder.sha256, "sha256");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = builder.version;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 generation() { return generation; }
    public UInt64 offset() { return offset; }
    public String sha256() { return sha256; }
    public UInt64 surface() { return surface; }
    public int version() { return version; }
    @Override public String event() { return "digest"; }

    public static DigestEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DigestEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "digest", "DigestEvent.event");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "DigestEvent.generation"));
        Object rawOffset = Wire.required(object, "offset");
        builder.offset(Wire.uint64(rawOffset, "DigestEvent.offset"));
        Object rawSha256 = Wire.required(object, "sha256");
        builder.sha256(Wire.string(rawSha256, "DigestEvent.sha256"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "DigestEvent.surface"));
        Object rawVersion = Wire.required(object, "version");
        builder.version(Wire.uint16(rawVersion, "DigestEvent.version"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "digest");
        Wire.put(object, "generation", generation);
        Wire.put(object, "offset", offset);
        Wire.put(object, "sha256", sha256);
        Wire.put(object, "surface", surface);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DigestEvent that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(offset, that.offset) && Objects.equals(sha256, that.sha256) && Objects.equals(surface, that.surface) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, offset, sha256, surface, version); }

    @Override
    public String toString() { return "DigestEvent" + toWire(); }

    public static final class Builder {
        private UInt64 generation;
        private boolean generationSet;
        private UInt64 offset;
        private boolean offsetSet;
        private String sha256;
        private boolean sha256Set;
        private UInt64 surface;
        private boolean surfaceSet;
        private Integer version;
        private boolean versionSet;

        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = value;
            this.offsetSet = true;
            return this;
        }
        public Builder sha256(String value) {
            this.sha256 = value;
            this.sha256Set = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder version(int value) {
            this.version = value;
            this.versionSet = true;
            return this;
        }
        public DigestEvent build() { return new DigestEvent(this); }
    }
}
