// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class WaitForResult implements WireValue {
    private final UInt64 elapsedMs;
    private final String text;

    private WaitForResult(Builder builder) {
        if (!builder.elapsedMsSet) throw new IllegalArgumentException("elapsed_ms is required");
        this.elapsedMs = Wire.nonNull(builder.elapsedMs, "elapsed_ms");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 elapsedMs() { return elapsedMs; }
    public Boolean matched() { return true; }
    public String text() { return text; }

    public static WaitForResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WaitForResult");
        Builder builder = builder();
        Object rawElapsedMs = Wire.required(object, "elapsed_ms");
        builder.elapsedMs(Wire.uint64(rawElapsedMs, "WaitForResult.elapsed_ms"));
        Object rawMatched = Wire.required(object, "matched");
        ProtocolSupport.literal(rawMatched, true, "WaitForResult.matched");
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "WaitForResult.text"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "elapsed_ms", elapsedMs);
        Wire.put(object, "matched", true);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WaitForResult that)) return false;
        return Objects.equals(elapsedMs, that.elapsedMs) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(elapsedMs, text); }

    @Override
    public String toString() { return "WaitForResult" + toWire(); }

    public static final class Builder {
        private UInt64 elapsedMs;
        private boolean elapsedMsSet;
        private String text;
        private boolean textSet;

        public Builder elapsedMs(UInt64 value) {
            this.elapsedMs = value;
            this.elapsedMsSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public WaitForResult build() { return new WaitForResult(this); }
    }
}
