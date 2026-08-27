// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-insert-text request. Protocol v6; authority: frontend. */
public final class BrowserInsertTextRequest implements WireValue {
    private final UInt64 surface;
    private final String text;

    private BrowserInsertTextRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }
    public String text() { return text; }

    public static BrowserInsertTextRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserInsertTextRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserInsertTextRequest.surface"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "BrowserInsertTextRequest.text"));
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
        if (!(other instanceof BrowserInsertTextRequest that)) return false;
        return Objects.equals(surface, that.surface) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(surface, text); }

    @Override
    public String toString() { return "BrowserInsertTextRequest" + toWire(); }

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
        public BrowserInsertTextRequest build() { return new BrowserInsertTextRequest(this); }
    }
}
