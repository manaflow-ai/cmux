// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ScriptRunResult implements WireValue {
    private final Field<UInt64> droppedLogLines;
    private final Object value;

    private ScriptRunResult(Builder builder) {
        this.droppedLogLines = builder.droppedLogLines;
        if (!builder.valueSet) throw new IllegalArgumentException("value is required");
        this.value = builder.value == null ? null : Wire.immutableJson(builder.value);
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> droppedLogLines() { return droppedLogLines; }
    public Object value() { return value; }

    public static ScriptRunResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptRunResult");
        Builder builder = builder();
        Object rawDroppedLogLines = Wire.optional(object, "dropped_log_lines");
        if (!Wire.isMissing(rawDroppedLogLines)) {
            builder.droppedLogLines(Wire.uint64(rawDroppedLogLines, "ScriptRunResult.dropped_log_lines"));
        }
        Object rawValue = Wire.required(object, "value");
        builder.value(rawValue == null ? null : Wire.immutableJson(rawValue));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dropped_log_lines", droppedLogLines);
        Wire.put(object, "value", value);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptRunResult that)) return false;
        return Objects.equals(droppedLogLines, that.droppedLogLines) && Objects.equals(value, that.value);
    }

    @Override
    public int hashCode() { return Objects.hash(droppedLogLines, value); }

    @Override
    public String toString() { return "ScriptRunResult" + toWire(); }

    public static final class Builder {
        private Field<UInt64> droppedLogLines = Field.omitted();
        private Object value;
        private boolean valueSet;

        public Builder droppedLogLines(UInt64 value) {
            this.droppedLogLines = Field.of(value);
            return this;
        }
        public Builder value(Object value) {
            this.value = value;
            this.valueSet = true;
            return this;
        }
        public ScriptRunResult build() { return new ScriptRunResult(this); }
    }
}
