// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-reaped event. Protocol v12; streams: subscribe. */
public final class TerminalReapedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final UInt64 graceMs;
    private final String terminal;
    private final String terminalId;

    private TerminalReapedEvent(Builder builder) {
        this.cause = builder.cause;
        if (!builder.graceMsSet) throw new IllegalArgumentException("grace_ms is required");
        this.graceMs = Wire.nonNull(builder.graceMs, "grace_ms");
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = builder.terminal;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<EventCause> cause() { return cause; }
    public UInt64 graceMs() { return graceMs; }
    public String terminal() { return terminal; }
    public String terminalId() { return terminalId; }
    @Override public String event() { return "terminal-reaped"; }

    public static TerminalReapedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalReapedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-reaped", "TerminalReapedEvent.event");
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawGraceMs = Wire.required(object, "grace_ms");
        builder.graceMs(Wire.uint64(rawGraceMs, "TerminalReapedEvent.grace_ms"));
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(rawTerminal == null ? null : Wire.string(rawTerminal, "TerminalReapedEvent.terminal"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalReapedEvent.terminal_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-reaped");
        Wire.put(object, "cause", cause);
        Wire.put(object, "grace_ms", graceMs);
        Wire.put(object, "terminal", terminal);
        Wire.put(object, "terminal_id", terminalId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalReapedEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(graceMs, that.graceMs) && Objects.equals(terminal, that.terminal) && Objects.equals(terminalId, that.terminalId);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, graceMs, terminal, terminalId); }

    @Override
    public String toString() { return "TerminalReapedEvent" + toWire(); }

    public static final class Builder {
        private Field<EventCause> cause = Field.omitted();
        private UInt64 graceMs;
        private boolean graceMsSet;
        private String terminal;
        private boolean terminalSet;
        private String terminalId;
        private boolean terminalIdSet;

        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder graceMs(UInt64 value) {
            this.graceMs = value;
            this.graceMsSet = true;
            return this;
        }
        public Builder terminal(String value) {
            this.terminal = value;
            this.terminalSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public TerminalReapedEvent build() { return new TerminalReapedEvent(this); }
    }
}
