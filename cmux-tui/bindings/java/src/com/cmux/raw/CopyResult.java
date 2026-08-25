// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class CopyResult implements WireValue {
    private final CopyResultMode mode;
    private final String text;

    private CopyResult(Builder builder) {
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public CopyResultMode mode() { return mode; }
    public String text() { return text; }

    public static CopyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CopyResult");
        Builder builder = builder();
        Object rawMode = Wire.required(object, "mode");
        builder.mode(CopyResultMode.fromWire(rawMode));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "CopyResult.text"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mode", mode);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CopyResult that)) return false;
        return Objects.equals(mode, that.mode) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(mode, text); }

    @Override
    public String toString() { return "CopyResult" + toWire(); }

    public static final class Builder {
        private CopyResultMode mode;
        private boolean modeSet;
        private String text;
        private boolean textSet;

        public Builder mode(CopyResultMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public CopyResult build() { return new CopyResult(this); }
    }
}
