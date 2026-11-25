// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalCommandContextResult implements WireValue {
    private final TerminalCommandContext context;

    private TerminalCommandContextResult(Builder builder) {
        if (!builder.contextSet) throw new IllegalArgumentException("context is required");
        this.context = builder.context;
    }

    public static Builder builder() { return new Builder(); }

    public TerminalCommandContext context() { return context; }

    public static TerminalCommandContextResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandContextResult");
        Builder builder = builder();
        Object rawContext = Wire.required(object, "context");
        builder.context(rawContext == null ? null : TerminalCommandContext.fromWire(rawContext));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "context", context);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandContextResult that)) return false;
        return Objects.equals(context, that.context);
    }

    @Override
    public int hashCode() { return Objects.hash(context); }

    @Override
    public String toString() { return "TerminalCommandContextResult" + toWire(); }

    public static final class Builder {
        private TerminalCommandContext context;
        private boolean contextSet;

        public Builder context(TerminalCommandContext value) {
            this.context = value;
            this.contextSet = true;
            return this;
        }
        public TerminalCommandContextResult build() { return new TerminalCommandContextResult(this); }
    }
}
