// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable fs.delete request. Protocol v12; authority: control. */
public final class FsDeleteRequest implements WireValue {
    private final List<String> paths;
    private final Field<Boolean> permanent;

    private FsDeleteRequest(Builder builder) {
        if (!builder.pathsSet) throw new IllegalArgumentException("paths is required");
        this.paths = List.copyOf(Wire.nonNull(builder.paths, "paths"));
        this.permanent = builder.permanent;
    }

    public static Builder builder() { return new Builder(); }

    public List<String> paths() { return paths; }
    public Field<Boolean> permanent() { return permanent; }

    public static FsDeleteRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsDeleteRequest");
        Builder builder = builder();
        Object rawPaths = Wire.required(object, "paths");
        builder.paths(Wire.array(rawPaths, "FsDeleteRequest.paths", item -> Wire.string(item, "FsDeleteRequest.paths item")));
        Object rawPermanent = Wire.optional(object, "permanent");
        if (!Wire.isMissing(rawPermanent)) {
            builder.permanent(Wire.bool(rawPermanent, "FsDeleteRequest.permanent"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "paths", paths);
        Wire.put(object, "permanent", permanent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsDeleteRequest that)) return false;
        return Objects.equals(paths, that.paths) && Objects.equals(permanent, that.permanent);
    }

    @Override
    public int hashCode() { return Objects.hash(paths, permanent); }

    @Override
    public String toString() { return "FsDeleteRequest" + toWire(); }

    public static final class Builder {
        private List<String> paths;
        private boolean pathsSet;
        private Field<Boolean> permanent = Field.omitted();

        public Builder paths(List<String> value) {
            this.paths = value;
            this.pathsSet = true;
            return this;
        }
        public Builder permanent(Boolean value) {
            this.permanent = Field.of(value);
            return this;
        }
        public FsDeleteRequest build() { return new FsDeleteRequest(this); }
    }
}
