// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable delete-terminal-commands request. Protocol v12; authority: local-admin. */
public final class DeleteTerminalCommandsRequest implements WireValue {
    private final Field<Boolean> all;
    private final Field<List<String>> ids;
    private final Field<String> startedSinceMs;

    private DeleteTerminalCommandsRequest(Builder builder) {
        this.all = builder.all;
        this.ids = builder.ids.map(value -> List.copyOf(value));
        this.startedSinceMs = builder.startedSinceMs;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> all() { return all; }
    public Field<List<String>> ids() { return ids; }
    public Field<String> startedSinceMs() { return startedSinceMs; }

    public static DeleteTerminalCommandsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteTerminalCommandsRequest");
        Builder builder = builder();
        Object rawAll = Wire.optional(object, "all");
        if (!Wire.isMissing(rawAll)) {
            builder.all(Wire.bool(rawAll, "DeleteTerminalCommandsRequest.all"));
        }
        Object rawIds = Wire.optional(object, "ids");
        if (!Wire.isMissing(rawIds)) {
            builder.ids(rawIds == null ? null : Wire.array(rawIds, "DeleteTerminalCommandsRequest.ids", item -> Wire.string(item, "DeleteTerminalCommandsRequest.ids item")));
        }
        Object rawStartedSinceMs = Wire.optional(object, "started_since_ms");
        if (!Wire.isMissing(rawStartedSinceMs)) {
            builder.startedSinceMs(rawStartedSinceMs == null ? null : Wire.string(rawStartedSinceMs, "DeleteTerminalCommandsRequest.started_since_ms"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "all", all);
        Wire.put(object, "ids", ids);
        Wire.put(object, "started_since_ms", startedSinceMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteTerminalCommandsRequest that)) return false;
        return Objects.equals(all, that.all) && Objects.equals(ids, that.ids) && Objects.equals(startedSinceMs, that.startedSinceMs);
    }

    @Override
    public int hashCode() { return Objects.hash(all, ids, startedSinceMs); }

    @Override
    public String toString() { return "DeleteTerminalCommandsRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> all = Field.omitted();
        private Field<List<String>> ids = Field.omitted();
        private Field<String> startedSinceMs = Field.omitted();

        public Builder all(Boolean value) {
            this.all = Field.of(value);
            return this;
        }
        public Builder ids(List<String> value) {
            this.ids = Field.ofNullable(value);
            return this;
        }
        public Builder startedSinceMs(String value) {
            this.startedSinceMs = Field.ofNullable(value);
            return this;
        }
        public DeleteTerminalCommandsRequest build() { return new DeleteTerminalCommandsRequest(this); }
    }
}
