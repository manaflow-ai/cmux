// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable list-terminal-commands request. Protocol v12; authority: local-admin. */
public final class ListTerminalCommandsRequest implements WireValue {
    private final Field<String> afterId;
    private final Field<Long> limit;

    private ListTerminalCommandsRequest(Builder builder) {
        this.afterId = builder.afterId;
        this.limit = builder.limit;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> afterId() { return afterId; }
    public Field<Long> limit() { return limit; }

    public static ListTerminalCommandsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ListTerminalCommandsRequest");
        Builder builder = builder();
        Object rawAfterId = Wire.optional(object, "after_id");
        if (!Wire.isMissing(rawAfterId)) {
            builder.afterId(rawAfterId == null ? null : Wire.string(rawAfterId, "ListTerminalCommandsRequest.after_id"));
        }
        Object rawLimit = Wire.optional(object, "limit");
        if (!Wire.isMissing(rawLimit)) {
            builder.limit(rawLimit == null ? null : Wire.uint32(rawLimit, "ListTerminalCommandsRequest.limit"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_id", afterId);
        Wire.put(object, "limit", limit);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ListTerminalCommandsRequest that)) return false;
        return Objects.equals(afterId, that.afterId) && Objects.equals(limit, that.limit);
    }

    @Override
    public int hashCode() { return Objects.hash(afterId, limit); }

    @Override
    public String toString() { return "ListTerminalCommandsRequest" + toWire(); }

    public static final class Builder {
        private Field<String> afterId = Field.omitted();
        private Field<Long> limit = Field.omitted();

        public Builder afterId(String value) {
            this.afterId = Field.ofNullable(value);
            return this;
        }
        public Builder limit(Long value) {
            this.limit = Field.ofNullable(value);
            return this;
        }
        public ListTerminalCommandsRequest build() { return new ListTerminalCommandsRequest(this); }
    }
}
