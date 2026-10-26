// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ScriptReplCloseResult implements WireValue {
    private final boolean closed;

    private ScriptReplCloseResult(Builder builder) {
        if (!builder.closedSet) throw new IllegalArgumentException("closed is required");
        this.closed = builder.closed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean closed() { return closed; }

    public static ScriptReplCloseResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptReplCloseResult");
        Builder builder = builder();
        Object rawClosed = Wire.required(object, "closed");
        builder.closed(Wire.bool(rawClosed, "ScriptReplCloseResult.closed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "closed", closed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptReplCloseResult that)) return false;
        return Objects.equals(closed, that.closed);
    }

    @Override
    public int hashCode() { return Objects.hash(closed); }

    @Override
    public String toString() { return "ScriptReplCloseResult" + toWire(); }

    public static final class Builder {
        private Boolean closed;
        private boolean closedSet;

        public Builder closed(boolean value) {
            this.closed = value;
            this.closedSet = true;
            return this;
        }
        public ScriptReplCloseResult build() { return new ScriptReplCloseResult(this); }
    }
}
