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
    private final UInt64 discardedInputBytes;
    private final UInt64 elapsedMs;
    private final String from;
    private final String registryTerminalId;
    private final UInt64 surface;
    private final String terminalId;
    private final String to_;

    private TerminalLifecycleEvent(Builder builder) {
        if (!builder.causeSet) throw new IllegalArgumentException("cause is required");
        this.cause = builder.cause;
        if (!builder.discardedInputBytesSet) throw new IllegalArgumentException("discarded_input_bytes is required");
        this.discardedInputBytes = Wire.nonNull(builder.discardedInputBytes, "discarded_input_bytes");
        if (!builder.elapsedMsSet) throw new IllegalArgumentException("elapsed_ms is required");
        this.elapsedMs = Wire.nonNull(builder.elapsedMs, "elapsed_ms");
        if (!builder.fromSet) throw new IllegalArgumentException("from is required");
        this.from = builder.from;
        if (!builder.registryTerminalIdSet) throw new IllegalArgumentException("registry_terminal_id is required");
        this.registryTerminalId = Wire.nonNull(builder.registryTerminalId, "registry_terminal_id");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = builder.surface;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = builder.terminalId;
        if (!builder.to_Set) throw new IllegalArgumentException("to is required");
        this.to_ = Wire.nonNull(builder.to_, "to");
    }

    public static Builder builder() { return new Builder(); }

    public String cause() { return cause; }
    public UInt64 discardedInputBytes() { return discardedInputBytes; }
    public UInt64 elapsedMs() { return elapsedMs; }
    public String from() { return from; }
    public String registryTerminalId() { return registryTerminalId; }
    public UInt64 surface() { return surface; }
    public String terminalId() { return terminalId; }
    public String to_() { return to_; }
    @Override public String event() { return "terminal-lifecycle"; }

    public static TerminalLifecycleEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLifecycleEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "terminal-lifecycle", "TerminalLifecycleEvent.event");
        Object rawCause = Wire.required(object, "cause");
        builder.cause(rawCause == null ? null : Wire.string(rawCause, "TerminalLifecycleEvent.cause"));
        Object rawDiscardedInputBytes = Wire.required(object, "discarded_input_bytes");
        builder.discardedInputBytes(Wire.uint64(rawDiscardedInputBytes, "TerminalLifecycleEvent.discarded_input_bytes"));
        Object rawElapsedMs = Wire.required(object, "elapsed_ms");
        builder.elapsedMs(Wire.uint64(rawElapsedMs, "TerminalLifecycleEvent.elapsed_ms"));
        Object rawFrom = Wire.required(object, "from");
        builder.from(rawFrom == null ? null : Wire.string(rawFrom, "TerminalLifecycleEvent.from"));
        Object rawRegistryTerminalId = Wire.required(object, "registry_terminal_id");
        builder.registryTerminalId(Wire.string(rawRegistryTerminalId, "TerminalLifecycleEvent.registry_terminal_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "TerminalLifecycleEvent.surface"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "TerminalLifecycleEvent.terminal_id"));
        Object rawTo = Wire.required(object, "to");
        builder.to_(Wire.string(rawTo, "TerminalLifecycleEvent.to"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "terminal-lifecycle");
        Wire.put(object, "cause", cause);
        Wire.put(object, "discarded_input_bytes", discardedInputBytes);
        Wire.put(object, "elapsed_ms", elapsedMs);
        Wire.put(object, "from", from);
        Wire.put(object, "registry_terminal_id", registryTerminalId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "to", to_);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLifecycleEvent that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(discardedInputBytes, that.discardedInputBytes) && Objects.equals(elapsedMs, that.elapsedMs) && Objects.equals(from, that.from) && Objects.equals(registryTerminalId, that.registryTerminalId) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(to_, that.to_);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, discardedInputBytes, elapsedMs, from, registryTerminalId, surface, terminalId, to_); }

    @Override
    public String toString() { return "TerminalLifecycleEvent" + toWire(); }

    public static final class Builder {
        private String cause;
        private boolean causeSet;
        private UInt64 discardedInputBytes;
        private boolean discardedInputBytesSet;
        private UInt64 elapsedMs;
        private boolean elapsedMsSet;
        private String from;
        private boolean fromSet;
        private String registryTerminalId;
        private boolean registryTerminalIdSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String to_;
        private boolean to_Set;

        public Builder cause(String value) {
            this.cause = value;
            this.causeSet = true;
            return this;
        }
        public Builder discardedInputBytes(UInt64 value) {
            this.discardedInputBytes = value;
            this.discardedInputBytesSet = true;
            return this;
        }
        public Builder elapsedMs(UInt64 value) {
            this.elapsedMs = value;
            this.elapsedMsSet = true;
            return this;
        }
        public Builder from(String value) {
            this.from = value;
            this.fromSet = true;
            return this;
        }
        public Builder registryTerminalId(String value) {
            this.registryTerminalId = value;
            this.registryTerminalIdSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder to_(String value) {
            this.to_ = value;
            this.to_Set = true;
            return this;
        }
        public TerminalLifecycleEvent build() { return new TerminalLifecycleEvent(this); }
    }
}
