// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalReadRangeResult implements WireValue {
    private final UInt64 surface;
    private final String text;

    private TerminalReadRangeResult(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public String text() { return text; }

    public static TerminalReadRangeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalReadRangeResult");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalReadRangeResult.surface"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "TerminalReadRangeResult.text"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalReadRangeResult that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, text); }

    @Override
    public String toString() { return "TerminalReadRangeResult" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;
        private String text;
        private boolean textSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public TerminalReadRangeResult build() { return new TerminalReadRangeResult(this); }
    }
}
