// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsDiskFile implements WireValue {
    private final UInt64 bytes;
    private final UInt64 files;
    private final String name;

    private ServerStatsDiskFile(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.filesSet) throw new IllegalArgumentException("files is required");
        this.files = Wire.nonNull(builder.files, "files");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public UInt64 files() { return files; }
    public String name() { return name; }

    public static ServerStatsDiskFile fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsDiskFile");
        Builder builder = builder();
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsDiskFile.bytes"));
        Object rawFiles = Wire.required(object, "files");
        builder.files(Wire.uint64(rawFiles, "ServerStatsDiskFile.files"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ServerStatsDiskFile.name"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "files", files);
        Wire.put(object, "name", name);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsDiskFile that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(files, that.files) && Objects.equals(name, that.name);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, files, name); }

    @Override
    public String toString() { return "ServerStatsDiskFile" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 files;
        private boolean filesSet;
        private String name;
        private boolean nameSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder files(UInt64 value) {
            this.files = value;
            this.filesSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public ServerStatsDiskFile build() { return new ServerStatsDiskFile(this); }
    }
}
