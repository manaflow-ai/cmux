// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.write request. Protocol v12; authority: control. */
public final class FsWriteRequest implements WireValue {
    private final Field<Bytes> bytesBase64;
    private final Field<String> expected;
    private final String mode;
    private final String path;
    private final Field<Long> permissions;
    private final Field<String> text;

    private FsWriteRequest(Builder builder) {
        this.bytesBase64 = builder.bytesBase64;
        this.expected = builder.expected;
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
        this.permissions = builder.permissions;
        this.text = builder.text;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Bytes> bytesBase64() { return bytesBase64; }
    public Field<String> expected() { return expected; }
    public String mode() { return mode; }
    public String path() { return path; }
    public Field<Long> permissions() { return permissions; }
    public Field<String> text() { return text; }

    public static FsWriteRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsWriteRequest");
        Builder builder = builder();
        Object rawBytesBase64 = Wire.optional(object, "bytes_base64");
        if (!Wire.isMissing(rawBytesBase64)) {
            builder.bytesBase64(rawBytesBase64 == null ? null : Wire.bytes(rawBytesBase64, "FsWriteRequest.bytes_base64"));
        }
        Object rawExpected = Wire.optional(object, "expected");
        if (!Wire.isMissing(rawExpected)) {
            builder.expected(rawExpected == null ? null : Wire.string(rawExpected, "FsWriteRequest.expected"));
        }
        Object rawMode = Wire.required(object, "mode");
        builder.mode(Wire.string(rawMode, "FsWriteRequest.mode"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "FsWriteRequest.path"));
        Object rawPermissions = Wire.optional(object, "permissions");
        if (!Wire.isMissing(rawPermissions)) {
            builder.permissions(rawPermissions == null ? null : Wire.uint32(rawPermissions, "FsWriteRequest.permissions"));
        }
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(rawText == null ? null : Wire.string(rawText, "FsWriteRequest.text"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes_base64", bytesBase64);
        Wire.put(object, "expected", expected);
        Wire.put(object, "mode", mode);
        Wire.put(object, "path", path);
        Wire.put(object, "permissions", permissions);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsWriteRequest that)) return false;
        return Objects.equals(bytesBase64, that.bytesBase64) && Objects.equals(expected, that.expected) && Objects.equals(mode, that.mode) && Objects.equals(path, that.path) && Objects.equals(permissions, that.permissions) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(bytesBase64, expected, mode, path, permissions, text); }

    @Override
    public String toString() { return "FsWriteRequest" + toWire(); }

    public static final class Builder {
        private Field<Bytes> bytesBase64 = Field.omitted();
        private Field<String> expected = Field.omitted();
        private String mode;
        private boolean modeSet;
        private String path;
        private boolean pathSet;
        private Field<Long> permissions = Field.omitted();
        private Field<String> text = Field.omitted();

        public Builder bytesBase64(Bytes value) {
            this.bytesBase64 = Field.ofNullable(value);
            return this;
        }
        public Builder expected(String value) {
            this.expected = Field.ofNullable(value);
            return this;
        }
        public Builder mode(String value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public Builder permissions(Long value) {
            this.permissions = Field.ofNullable(value);
            return this;
        }
        public Builder text(String value) {
            this.text = Field.ofNullable(value);
            return this;
        }
        public FsWriteRequest build() { return new FsWriteRequest(this); }
    }
}
