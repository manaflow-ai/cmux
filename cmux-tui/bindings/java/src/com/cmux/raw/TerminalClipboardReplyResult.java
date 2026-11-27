// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalClipboardReplyResult implements WireValue {
    private final boolean accepted;
    private final boolean granted;

    private TerminalClipboardReplyResult(Builder builder) {
        if (!builder.acceptedSet) throw new IllegalArgumentException("accepted is required");
        this.accepted = builder.accepted;
        if (!builder.grantedSet) throw new IllegalArgumentException("granted is required");
        this.granted = builder.granted;
    }

    public static Builder builder() { return new Builder(); }

    public boolean accepted() { return accepted; }
    public boolean granted() { return granted; }

    public static TerminalClipboardReplyResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardReplyResult");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        builder.accepted(Wire.bool(rawAccepted, "TerminalClipboardReplyResult.accepted"));
        Object rawGranted = Wire.required(object, "granted");
        builder.granted(Wire.bool(rawGranted, "TerminalClipboardReplyResult.granted"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", accepted);
        Wire.put(object, "granted", granted);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardReplyResult that)) return false;
        return Objects.equals(accepted, that.accepted) && Objects.equals(granted, that.granted);
    }

    @Override
    public int hashCode() { return Objects.hash(accepted, granted); }

    @Override
    public String toString() { return "TerminalClipboardReplyResult" + toWire(); }

    public static final class Builder {
        private Boolean accepted;
        private boolean acceptedSet;
        private Boolean granted;
        private boolean grantedSet;

        public Builder accepted(boolean value) {
            this.accepted = value;
            this.acceptedSet = true;
            return this;
        }
        public Builder granted(boolean value) {
            this.granted = value;
            this.grantedSet = true;
            return this;
        }
        public TerminalClipboardReplyResult build() { return new TerminalClipboardReplyResult(this); }
    }
}
