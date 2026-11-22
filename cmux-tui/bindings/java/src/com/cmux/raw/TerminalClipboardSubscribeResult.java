// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalClipboardSubscribeResult implements WireValue {
    private final boolean clipboardReadReady;

    private TerminalClipboardSubscribeResult(Builder builder) {
        if (!builder.clipboardReadReadySet) throw new IllegalArgumentException("clipboard_read_ready is required");
        this.clipboardReadReady = builder.clipboardReadReady;
    }

    public static Builder builder() { return new Builder(); }

    public boolean clipboardReadReady() { return clipboardReadReady; }

    public static TerminalClipboardSubscribeResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardSubscribeResult");
        Builder builder = builder();
        Object rawClipboardReadReady = Wire.required(object, "clipboard_read_ready");
        builder.clipboardReadReady(Wire.bool(rawClipboardReadReady, "TerminalClipboardSubscribeResult.clipboard_read_ready"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "clipboard_read_ready", clipboardReadReady);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardSubscribeResult that)) return false;
        return Objects.equals(clipboardReadReady, that.clipboardReadReady);
    }

    @Override
    public int hashCode() { return Objects.hash(clipboardReadReady); }

    @Override
    public String toString() { return "TerminalClipboardSubscribeResult" + toWire(); }

    public static final class Builder {
        private Boolean clipboardReadReady;
        private boolean clipboardReadReadySet;

        public Builder clipboardReadReady(boolean value) {
            this.clipboardReadReady = value;
            this.clipboardReadReadySet = true;
            return this;
        }
        public TerminalClipboardSubscribeResult build() { return new TerminalClipboardSubscribeResult(this); }
    }
}
