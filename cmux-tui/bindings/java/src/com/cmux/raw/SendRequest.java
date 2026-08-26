// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable send request. Protocol v5; authority: control. */
public final class SendRequest implements WireValue {
    private final Field<Bytes> bytes;
    private final Field<Boolean> paste;
    private final UInt64 surface;
    private final Field<String> text;

    private SendRequest(Builder builder) {
        this.bytes = builder.bytes;
        this.paste = builder.paste;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.text = builder.text;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Bytes> bytes() { return bytes; }
    public Field<Boolean> paste() { return paste; }
    public UInt64 surface() { return surface; }
    public Field<String> text() { return text; }

    public static SendRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendRequest");
        Builder builder = builder();
        Object rawBytes = Wire.optional(object, "bytes");
        if (!Wire.isMissing(rawBytes)) {
            builder.bytes(rawBytes == null ? null : Wire.bytes(rawBytes, "SendRequest.bytes"));
        }
        Object rawPaste = Wire.optional(object, "paste");
        if (!Wire.isMissing(rawPaste)) {
            builder.paste(Wire.bool(rawPaste, "SendRequest.paste"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SendRequest.surface"));
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(rawText == null ? null : Wire.string(rawText, "SendRequest.text"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "paste", paste);
        Wire.put(object, "surface", surface);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendRequest that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(paste, that.paste) && Objects.equals(surface, that.surface) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, paste, surface, text); }

    @Override
    public String toString() { return "SendRequest" + toWire(); }

    public static final class Builder {
        private Field<Bytes> bytes = Field.omitted();
        private Field<Boolean> paste = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> text = Field.omitted();

        public Builder bytes(Bytes value) {
            this.bytes = Field.ofNullable(value);
            return this;
        }
        public Builder paste(Boolean value) {
            this.paste = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = Field.ofNullable(value);
            return this;
        }
        public SendRequest build() { return new SendRequest(this); }
    }
}
