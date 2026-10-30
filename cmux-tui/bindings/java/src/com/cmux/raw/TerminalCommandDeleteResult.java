// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalCommandDeleteResult implements WireValue {
    private final UInt64 deleted;

    private TerminalCommandDeleteResult(Builder builder) {
        if (!builder.deletedSet) throw new IllegalArgumentException("deleted is required");
        this.deleted = Wire.nonNull(builder.deleted, "deleted");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 deleted() { return deleted; }

    public static TerminalCommandDeleteResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandDeleteResult");
        Builder builder = builder();
        Object rawDeleted = Wire.required(object, "deleted");
        builder.deleted(Wire.uint64(rawDeleted, "TerminalCommandDeleteResult.deleted"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "deleted", deleted);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandDeleteResult that)) return false;
        return Objects.equals(deleted, that.deleted);
    }

    @Override
    public int hashCode() { return Objects.hash(deleted); }

    @Override
    public String toString() { return "TerminalCommandDeleteResult" + toWire(); }

    public static final class Builder {
        private UInt64 deleted;
        private boolean deletedSet;

        public Builder deleted(UInt64 value) {
            this.deleted = value;
            this.deletedSet = true;
            return this;
        }
        public TerminalCommandDeleteResult build() { return new TerminalCommandDeleteResult(this); }
    }
}
