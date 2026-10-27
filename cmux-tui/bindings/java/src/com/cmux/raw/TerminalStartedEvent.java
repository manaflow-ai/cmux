// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-started event. Protocol v12; streams: control. */
public final class TerminalStartedEvent implements WireValue, ProtocolEvent {
    private final String mutationId;
    private final TerminalPlacement result;
    private final String terminalId;

    private TerminalStartedEvent(Builder builder) {
        if (!builder.mutationIdSet) throw new IllegalArgumentException("mutation_id is required");
        this.mutationId = Wire.nonNull(builder.mutationId, "mutation_id");
        if (!builder.resultSet) throw new IllegalArgumentException("result is required");
        this.result = Wire.nonNull(builder.result, "result");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public String mutationId() { return mutationId; }
    public TerminalPlacement result() { return result; }
    public String terminalId() { return terminalId; }
    @Override public String event() { return "terminal-started"; }

    public static TerminalStartedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalStartedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-started", "TerminalStartedEvent.event");
        Object rawMutationId = Wire.required(object, "mutation_id");
        builder.mutationId(Wire.string(rawMutationId, "TerminalStartedEvent.mutation_id"));
        Object rawResult = Wire.required(object, "result");
        builder.result(TerminalPlacement.fromWire(rawResult));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalStartedEvent.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-started");
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "result", result);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalStartedEvent that)) return false;
        return Objects.equals(mutationId, that.mutationId) && Objects.equals(result, that.result) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(mutationId, result, terminalId); }

    @Override
    public String toString() { return "TerminalStartedEvent" + toWire(); }

    public static final class Builder {
        private String mutationId;
        private boolean mutationIdSet;
        private TerminalPlacement result;
        private boolean resultSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder mutationId(String value) {
            this.mutationId = value;
            this.mutationIdSet = true;
            return this;
        }
        public Builder result(TerminalPlacement value) {
            this.result = value;
            this.resultSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalStartedEvent build() { return new TerminalStartedEvent(this); }
    }
}
