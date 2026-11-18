// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-command-context request. Protocol v12; authority: control. */
public final class TerminalCommandContextRequest implements WireValue {
    private final Field<TerminalCommandContextIntent> intent;
    private final UInt64 surface;

    private TerminalCommandContextRequest(Builder builder) {
        this.intent = builder.intent;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalCommandContextIntent> intent() { return intent; }
    public UInt64 surface() { return surface; }

    public static TerminalCommandContextRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandContextRequest");
        Builder builder = builder();
        Object rawIntent = Wire.optional(object, "intent");
        if (!Wire.isMissing(rawIntent)) {
            builder.intent(TerminalCommandContextIntent.fromWire(rawIntent));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalCommandContextRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "intent", intent);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandContextRequest that)) return false;
        return Objects.equals(intent, that.intent) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(intent, surface); }

    @Override
    public String toString() { return "TerminalCommandContextRequest" + toWire(); }

    public static final class Builder {
        private Field<TerminalCommandContextIntent> intent = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder intent(TerminalCommandContextIntent value) {
            this.intent = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public TerminalCommandContextRequest build() { return new TerminalCommandContextRequest(this); }
    }
}
