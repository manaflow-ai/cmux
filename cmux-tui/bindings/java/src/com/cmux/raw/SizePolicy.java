// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SizePolicy implements WireValue {
    private final Field<Size> fixed;
    private final Field<SizeMode> mode;
    private final Field<List<String>> priority;

    private SizePolicy(Builder builder) {
        this.fixed = builder.fixed;
        this.mode = builder.mode;
        this.priority = builder.priority.map(value -> List.copyOf(value));
    }

    public static Builder builder() { return new Builder(); }

    public Field<Size> fixed() { return fixed; }
    public Field<SizeMode> mode() { return mode; }
    public Field<List<String>> priority() { return priority; }

    public static SizePolicy fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SizePolicy");
        Builder builder = builder();
        Object rawFixed = Wire.optional(object, "fixed");
        if (!Wire.isMissing(rawFixed)) {
            builder.fixed(rawFixed == null ? null : Size.fromWire(rawFixed));
        }
        Object rawMode = Wire.optional(object, "mode");
        if (!Wire.isMissing(rawMode)) {
            builder.mode(SizeMode.fromWire(rawMode));
        }
        Object rawPriority = Wire.optional(object, "priority");
        if (!Wire.isMissing(rawPriority)) {
            builder.priority(Wire.array(rawPriority, "SizePolicy.priority", item -> Wire.string(item, "SizePolicy.priority item")));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "fixed", fixed);
        Wire.put(object, "mode", mode);
        Wire.put(object, "priority", priority);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SizePolicy that)) return false;
        return Objects.equals(fixed, that.fixed) && Objects.equals(mode, that.mode) && Objects.equals(priority, that.priority);
    }

    @Override
    public int hashCode() { return Objects.hash(fixed, mode, priority); }

    @Override
    public String toString() { return "SizePolicy" + toWire(); }

    public static final class Builder {
        private Field<Size> fixed = Field.omitted();
        private Field<SizeMode> mode = Field.omitted();
        private Field<List<String>> priority = Field.omitted();

        public Builder fixed(Size value) {
            this.fixed = Field.ofNullable(value);
            return this;
        }
        public Builder mode(SizeMode value) {
            this.mode = Field.of(value);
            return this;
        }
        public Builder priority(List<String> value) {
            this.priority = Field.of(value);
            return this;
        }
        public SizePolicy build() { return new SizePolicy(this); }
    }
}
