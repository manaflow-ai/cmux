// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable browser-key-press request. Protocol v10; authority: frontend. */
public final class BrowserKeyPressRequest implements WireValue {
    private final String code;
    private final String key;
    private final long modifiers;
    private final UInt64 surface;
    private final Field<String> text;
    private final long windowsVirtualKeyCode;

    private BrowserKeyPressRequest(Builder builder) {
        if (!builder.codeSet) throw new IllegalArgumentException("code is required");
        this.code = Wire.nonNull(builder.code, "code");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.modifiersSet) throw new IllegalArgumentException("modifiers is required");
        this.modifiers = builder.modifiers;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.text = builder.text;
        if (!builder.windowsVirtualKeyCodeSet) throw new IllegalArgumentException("windows_virtual_key_code is required");
        this.windowsVirtualKeyCode = builder.windowsVirtualKeyCode;
    }

    public static Builder builder() { return new Builder(); }

    public String code() { return code; }
    public String key() { return key; }
    public long modifiers() { return modifiers; }
    public UInt64 surface() { return surface; }
    public Field<String> text() { return text; }
    public long windowsVirtualKeyCode() { return windowsVirtualKeyCode; }

    public static BrowserKeyPressRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserKeyPressRequest");
        Builder builder = builder();
        Object rawCode = Wire.required(object, "code");
        builder.code(Wire.string(rawCode, "BrowserKeyPressRequest.code"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "BrowserKeyPressRequest.key"));
        Object rawModifiers = Wire.required(object, "modifiers");
        builder.modifiers(Wire.uint32(rawModifiers, "BrowserKeyPressRequest.modifiers"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BrowserKeyPressRequest.surface"));
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(rawText == null ? null : Wire.string(rawText, "BrowserKeyPressRequest.text"));
        }
        Object rawWindowsVirtualKeyCode = Wire.required(object, "windows_virtual_key_code");
        builder.windowsVirtualKeyCode(Wire.uint32(rawWindowsVirtualKeyCode, "BrowserKeyPressRequest.windows_virtual_key_code"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "code", code);
        Wire.put(object, "key", key);
        Wire.put(object, "modifiers", modifiers);
        Wire.put(object, "surface", surface);
        Wire.put(object, "text", text);
        Wire.put(object, "windows_virtual_key_code", windowsVirtualKeyCode);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserKeyPressRequest that)) return false;
        return Objects.equals(code, that.code) && Objects.equals(key, that.key) && Objects.equals(modifiers, that.modifiers) && Objects.equals(surface, that.surface) && Objects.equals(text, that.text) && Objects.equals(windowsVirtualKeyCode, that.windowsVirtualKeyCode);
    }

    @Override
    public int hashCode() { return Objects.hash(code, key, modifiers, surface, text, windowsVirtualKeyCode); }

    @Override
    public String toString() { return "BrowserKeyPressRequest" + toWire(); }

    public static final class Builder {
        private String code;
        private boolean codeSet;
        private String key;
        private boolean keySet;
        private Long modifiers;
        private boolean modifiersSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> text = Field.omitted();
        private Long windowsVirtualKeyCode;
        private boolean windowsVirtualKeyCodeSet;

        public Builder code(String value) {
            this.code = value;
            this.codeSet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder modifiers(long value) {
            this.modifiers = value;
            this.modifiersSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = Field.ofNullable(value);
            return this;
        }
        public Builder windowsVirtualKeyCode(long value) {
            this.windowsVirtualKeyCode = value;
            this.windowsVirtualKeyCodeSet = true;
            return this;
        }
        public BrowserKeyPressRequest build() { return new BrowserKeyPressRequest(this); }
    }
}
