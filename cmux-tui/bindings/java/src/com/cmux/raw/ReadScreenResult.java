// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReadScreenResult implements WireValue {
    private final String text;

    private ReadScreenResult(Builder builder) {
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public String text() { return text; }

    public static ReadScreenResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReadScreenResult");
        Builder builder = builder();
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "ReadScreenResult.text"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReadScreenResult that)) return false;
        return Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(text); }

    @Override
    public String toString() { return "ReadScreenResult" + toWire(); }

    public static final class Builder {
        private String text;
        private boolean textSet;

        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public ReadScreenResult build() { return new ReadScreenResult(this); }
    }
}
