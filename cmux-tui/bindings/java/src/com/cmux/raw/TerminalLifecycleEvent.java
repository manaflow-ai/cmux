// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-lifecycle event. Protocol v12; streams: subscribe. */
public final class TerminalLifecycleEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String cause;
    private final UInt64 elapsedMs;
    private final String terminal;
    private final String terminalId;
    private final String terminalIncarnation;
    private final TerminalLifecycleEventTo to_;

    private TerminalLifecycleEvent(Builder builder) {
        if (!builder.causeSet) throw new IllegalArgumentException("cause is required");
        this.cause = builder.cause;
        if (!builder.elapsedMsSet) throw new IllegalArgumentException("elapsed_ms is required");
        this.elapsedMs = Wire.nonNull(builder.elapsedMs, "elapsed_ms");
        if (!builder.terminalSet) throw new IllegalArgumentException("terminal is required");
        this.terminal = builder.terminal;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.terminalIncarnationSet) throw new IllegalArgumentException("terminal_incarnation is required");
        this.terminalIncarnation = builder.terminalIncarnation;
        if (!builder.to_Set) throw new IllegalArgumentException("to is required");
        this.to_ = Wire.nonNull(builder.to_, "to");
    }

    public static Builder builder() { return new Builder(); }

    public String cause() { return cause; }
    public UInt64 elapsedMs() { return elapsedMs; }
    public String from() { return "launching"; }
    public String terminal() { return terminal; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public TerminalLifecycleEventTo to_() { return to_; }
    @Override public String event() { return "terminal-lifecycle"; }

    public static TerminalLifecycleEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLifecycleEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-lifecycle", "TerminalLifecycleEvent.event");
        Object rawCause = Wire.required(object, "cause");
        builder.cause(rawCause == null ? null : Wire.string(rawCause, "TerminalLifecycleEvent.cause"));
        Object rawElapsedMs = Wire.required(object, "elapsed_ms");
        builder.elapsedMs(Wire.uint64(rawElapsedMs, "TerminalLifecycleEvent.elapsed_ms"));
        Object rawFrom = Wire.required(object, "from");
        ProtocolSupport.literal(rawFrom, "launching", "TerminalLifecycleEvent.from");
        Object rawTerminal = Wire.required(object, "terminal");
        builder.terminal(rawTerminal == null ? null : Wire.string(rawTerminal, "TerminalLifecycleEvent.terminal"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalLifecycleEvent.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "TerminalLifecycleEvent.terminal_incarnation"));
        Object rawTo = Wire.required(object, "to");
        builder.to_(TerminalLifecycleEventTo.fromWire(rawTo));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-lifecycle");
        Wire.put(object, "cause", cause);
        Wire.put(object, "elapsed_ms", elapsedMs);
        Wire.put(object, "from", "launching");
        Wire.put(object, "terminal", terminal);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "to", to_);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLifecycleEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(elapsedMs, that.elapsedMs) && Objects.equals(terminal, that.terminal) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(to_, that.to_);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, elapsedMs, terminal, terminalId, terminalIncarnation, to_); }

    @Override
    public String toString() { return "TerminalLifecycleEvent" + toWire(); }

    public static final class Builder {
        private String cause;
        private boolean causeSet;
        private UInt64 elapsedMs;
        private boolean elapsedMsSet;
        private String terminal;
        private boolean terminalSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String terminalIncarnation;
        private boolean terminalIncarnationSet;
        private TerminalLifecycleEventTo to_;
        private boolean to_Set;

        public Builder cause(String value) {
            this.cause = value;
            this.causeSet = true;
            return this;
        }
        public Builder elapsedMs(UInt64 value) {
            this.elapsedMs = value;
            this.elapsedMsSet = true;
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
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = value;
            this.terminalIncarnationSet = true;
            return this;
        }
        public Builder to_(TerminalLifecycleEventTo value) {
            this.to_ = value;
            this.to_Set = true;
            return this;
        }
        public TerminalLifecycleEvent build() { return new TerminalLifecycleEvent(this); }
    }
}
