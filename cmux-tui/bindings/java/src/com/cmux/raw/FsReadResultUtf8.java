// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsReadResultUtf8 implements WireValue, FsReadResult {
    private final UInt64 size;
    private final String text;
    private final boolean truncated;

    private FsReadResultUtf8(Builder builder) {
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = Wire.nonNull(builder.size, "size");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public String encoding() { return "utf-8"; }
    public UInt64 size() { return size; }
    public String text() { return text; }
    public boolean truncated() { return truncated; }

    public static FsReadResultUtf8 fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsReadResultUtf8");
        Builder builder = builder();
        Object rawEncoding = Wire.required(object, "encoding");
        ProtocolSupport.literal(rawEncoding, "utf-8", "FsReadResultUtf8.encoding");
        Object rawSize = Wire.required(object, "size");
        builder.size(Wire.uint64(rawSize, "FsReadResultUtf8.size"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "FsReadResultUtf8.text"));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "FsReadResultUtf8.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "encoding", "utf-8");
        Wire.put(object, "size", size);
        Wire.put(object, "text", text);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsReadResultUtf8 that)) return false;
        return Objects.equals(size, that.size) && Objects.equals(text, that.text) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(size, text, truncated); }

    @Override
    public String toString() { return "FsReadResultUtf8" + toWire(); }

    public static final class Builder {
        private UInt64 size;
        private boolean sizeSet;
        private String text;
        private boolean textSet;
        private Boolean truncated;
        private boolean truncatedSet;

        public Builder size(UInt64 value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public FsReadResultUtf8 build() { return new FsReadResultUtf8(this); }
    }
}
