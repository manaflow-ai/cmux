// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-start-failed event. Protocol v12; streams: control. */
public final class TerminalStartFailedEvent implements WireValue, ProtocolEvent {
    private final String error;
    private final String errorCode;
    private final String key;
    private final String mutationId;
    private final String terminalId;

    private TerminalStartFailedEvent(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = Wire.nonNull(builder.error, "error");
        if (!builder.errorCodeSet) throw new IllegalArgumentException("error_code is required");
        this.errorCode = builder.errorCode;
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.mutationIdSet) throw new IllegalArgumentException("mutation_id is required");
        this.mutationId = Wire.nonNull(builder.mutationId, "mutation_id");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public String errorCode() { return errorCode; }
    public String key() { return key; }
    public String mutationId() { return mutationId; }
    public String terminalId() { return terminalId; }
    @Override public String event() { return "terminal-start-failed"; }

    public static TerminalStartFailedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalStartFailedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-start-failed", "TerminalStartFailedEvent.event");
        Object rawError = Wire.required(object, "error");
        builder.error(Wire.string(rawError, "TerminalStartFailedEvent.error"));
        Object rawErrorCode = Wire.required(object, "error_code");
        builder.errorCode(rawErrorCode == null ? null : Wire.string(rawErrorCode, "TerminalStartFailedEvent.error_code"));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "TerminalStartFailedEvent.key"));
        Object rawMutationId = Wire.required(object, "mutation_id");
        builder.mutationId(Wire.string(rawMutationId, "TerminalStartFailedEvent.mutation_id"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalStartFailedEvent.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-start-failed");
        Wire.put(object, "error", error);
        Wire.put(object, "error_code", errorCode);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalStartFailedEvent that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(errorCode, that.errorCode) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(error, errorCode, key, mutationId, terminalId); }

    @Override
    public String toString() { return "TerminalStartFailedEvent" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private String errorCode;
        private boolean errorCodeSet;
        private String key;
        private boolean keySet;
        private String mutationId;
        private boolean mutationIdSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder errorCode(String value) {
            this.errorCode = value;
            this.errorCodeSet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = value;
            this.mutationIdSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalStartFailedEvent build() { return new TerminalStartFailedEvent(this); }
    }
}
