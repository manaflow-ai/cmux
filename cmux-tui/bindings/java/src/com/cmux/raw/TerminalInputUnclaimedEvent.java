// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-input-unclaimed event. Protocol v12; streams: control. */
public final class TerminalInputUnclaimedEvent implements WireValue, ProtocolEvent {
    private final Bytes bytesBase64;
    private final String reason;
    private final String terminalId;

    private TerminalInputUnclaimedEvent(Builder builder) {
        if (!builder.bytesBase64Set) throw new IllegalArgumentException("bytes_base64 is required");
        this.bytesBase64 = Wire.nonNull(builder.bytesBase64, "bytes_base64");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public Bytes bytesBase64() { return bytesBase64; }
    public String reason() { return reason; }
    public String terminalId() { return terminalId; }
    @Override public String event() { return "terminal-input-unclaimed"; }

    public static TerminalInputUnclaimedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalInputUnclaimedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-input-unclaimed", "TerminalInputUnclaimedEvent.event");
        Object rawBytesBase64 = Wire.required(object, "bytes_base64");
        builder.bytesBase64(Wire.bytes(rawBytesBase64, "TerminalInputUnclaimedEvent.bytes_base64"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(Wire.string(rawReason, "TerminalInputUnclaimedEvent.reason"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalInputUnclaimedEvent.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-input-unclaimed");
        Wire.put(object, "bytes_base64", bytesBase64);
        Wire.put(object, "reason", reason);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalInputUnclaimedEvent that)) return false;
        return Objects.equals(bytesBase64, that.bytesBase64) && Objects.equals(reason, that.reason) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(bytesBase64, reason, terminalId); }

    @Override
    public String toString() { return "TerminalInputUnclaimedEvent" + toWire(); }

    public static final class Builder {
        private Bytes bytesBase64;
        private boolean bytesBase64Set;
        private String reason;
        private boolean reasonSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder bytesBase64(Bytes value) {
            this.bytesBase64 = value;
            this.bytesBase64Set = true;
            return this;
        }
        public Builder reason(String value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalInputUnclaimedEvent build() { return new TerminalInputUnclaimedEvent(this); }
    }
}
