// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-events request. Protocol v9; authority: control. */
public final class TerminalEventsRequest implements WireValue {
    private final Field<UInt64> afterRevision;

    private TerminalEventsRequest(Builder builder) {
        this.afterRevision = builder.afterRevision;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterRevision() { return afterRevision; }

    public static TerminalEventsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalEventsRequest");
        Builder builder = builder();
        Object rawAfterRevision = Wire.optional(object, "after_revision");
        if (!Wire.isMissing(rawAfterRevision)) {
            builder.afterRevision(Wire.uint64(rawAfterRevision, "TerminalEventsRequest.after_revision"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_revision", afterRevision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalEventsRequest that)) return false;
        return Objects.equals(afterRevision, that.afterRevision);
    }

    @Override
    public int hashCode() { return Objects.hash(afterRevision); }

    @Override
    public String toString() { return "TerminalEventsRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterRevision = Field.omitted();

        public Builder afterRevision(UInt64 value) {
            this.afterRevision = Field.of(value);
            return this;
        }
        public TerminalEventsRequest build() { return new TerminalEventsRequest(this); }
    }
}
