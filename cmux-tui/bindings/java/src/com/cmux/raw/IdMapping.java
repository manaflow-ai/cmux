// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class IdMapping implements WireValue {
    private final UInt64 id;
    private final IdMappingKind kind;
    private final String shortId;

    private IdMapping(Builder builder) {
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.shortIdSet) throw new IllegalArgumentException("short_id is required");
        this.shortId = Wire.nonNull(builder.shortId, "short_id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 id() { return id; }
    public IdMappingKind kind() { return kind; }
    public String shortId() { return shortId; }

    public static IdMapping fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdMapping");
        Builder builder = builder();
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "IdMapping.id"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(IdMappingKind.fromWire(rawKind));
        Object rawShortId = Wire.required(object, "short_id");
        builder.shortId(Wire.string(rawShortId, "IdMapping.short_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "id", id);
        Wire.put(object, "kind", kind);
        Wire.put(object, "short_id", shortId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdMapping that)) return false;
        return Objects.equals(id, that.id) && Objects.equals(kind, that.kind) && Objects.equals(shortId, that.shortId);
    }

    @Override
    public int hashCode() { return Objects.hash(id, kind, shortId); }

    @Override
    public String toString() { return "IdMapping" + toWire(); }

    public static final class Builder {
        private UInt64 id;
        private boolean idSet;
        private IdMappingKind kind;
        private boolean kindSet;
        private String shortId;
        private boolean shortIdSet;

        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder kind(IdMappingKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = value;
            this.shortIdSet = true;
            return this;
        }
        public IdMapping build() { return new IdMapping(this); }
    }
}
