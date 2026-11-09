// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable server-stats request. Protocol v12; authority: local-admin. */
public final class ServerStatsRequest implements WireValue {
    private final Field<List<String>> include;
    private final Field<Boolean> restoreProgress;

    private ServerStatsRequest(Builder builder) {
        this.include = builder.include.map(value -> List.copyOf(value));
        this.restoreProgress = builder.restoreProgress;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> include() { return include; }
    public Field<Boolean> restoreProgress() { return restoreProgress; }

    public static ServerStatsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRequest");
        Builder builder = builder();
        Object rawInclude = Wire.optional(object, "include");
        if (!Wire.isMissing(rawInclude)) {
            builder.include(rawInclude == null ? null : Wire.array(rawInclude, "ServerStatsRequest.include", item -> Wire.string(item, "ServerStatsRequest.include item")));
        }
        Object rawRestoreProgress = Wire.optional(object, "restore_progress");
        if (!Wire.isMissing(rawRestoreProgress)) {
            builder.restoreProgress(Wire.bool(rawRestoreProgress, "ServerStatsRequest.restore_progress"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "include", include);
        Wire.put(object, "restore_progress", restoreProgress);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRequest that)) return false;
        return Objects.equals(include, that.include) && Objects.equals(restoreProgress, that.restoreProgress);
    }

    @Override
    public int hashCode() { return Objects.hash(include, restoreProgress); }

    @Override
    public String toString() { return "ServerStatsRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> include = Field.omitted();
        private Field<Boolean> restoreProgress = Field.omitted();

        public Builder include(List<String> value) {
            this.include = Field.ofNullable(value);
            return this;
        }
        public Builder restoreProgress(Boolean value) {
            this.restoreProgress = Field.of(value);
            return this;
        }
        public ServerStatsRequest build() { return new ServerStatsRequest(this); }
    }
}
