// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.stat request. Protocol v12; authority: control. */
public final class FsStatRequest implements WireValue {
    private final String path;

    private FsStatRequest(Builder builder) {
        if (!builder.pathSet) throw new IllegalArgumentException("path is required");
        this.path = Wire.nonNull(builder.path, "path");
    }

    public static Builder builder() { return new Builder(); }

    public String path() { return path; }

    public static FsStatRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsStatRequest");
        Builder builder = builder();
        Object rawPath = Wire.required(object, "path");
        builder.path(Wire.string(rawPath, "FsStatRequest.path"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "path", path);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsStatRequest that)) return false;
        return Objects.equals(path, that.path);
    }

    @Override
    public int hashCode() { return Objects.hash(path); }

    @Override
    public String toString() { return "FsStatRequest" + toWire(); }

    public static final class Builder {
        private String path;
        private boolean pathSet;

        public Builder path(String value) {
            this.path = value;
            this.pathSet = true;
            return this;
        }
        public FsStatRequest build() { return new FsStatRequest(this); }
    }
}
