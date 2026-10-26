// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.rename request. Protocol v12; authority: control. */
public final class FsRenameRequest implements WireValue {
    private final String name;
    private final String path;

    private FsRenameRequest(Builder builder) {
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
    }

    public static Builder builder() { return new Builder(); }

    public String name() { return name; }
    public String path() { return path; }

    public static FsRenameRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsRenameRequest");
        Builder builder = builder();
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "FsRenameRequest.name"));
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "FsRenameRequest.path"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "path", path);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsRenameRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(path, that.path);
    }

    @Override
    public int hashCode() { return Objects.hash(name, path); }

    @Override
    public String toString() { return "FsRenameRequest" + toWire(); }

    public static final class Builder {
        private String name;
        private boolean nameSet;
        private String path;
        private boolean pathSet;

        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public FsRenameRequest build() { return new FsRenameRequest(this); }
    }
}
