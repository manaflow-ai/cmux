// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalLossCause implements WireValue {
    /** Whether the host had panicked. */
    private final boolean panicked;
    /** The sender's process name, when it still ran when recorded and its pid was not reused. */
    private final Field<String> senderName;
    /** The pid that sent `signal`; null when the host could not tell. */
    private final Field<Long> senderPid;
    /** Conventional name of the first signal the host recorded (`SIGTERM`). */
    private final Field<String> signal;
    private final Map<String, Object> additionalProperties;

    private TerminalLossCause(Builder builder) {
        if (!builder.panickedSet) throw new IllegalArgumentException("panicked is required");
        this.panicked = builder.panicked;
        this.senderName = builder.senderName;
        this.senderPid = builder.senderPid;
        this.signal = builder.signal;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public boolean panicked() { return panicked; }
    public Field<String> senderName() { return senderName; }
    public Field<Long> senderPid() { return senderPid; }
    public Field<String> signal() { return signal; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TerminalLossCause fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalLossCause");
        Builder builder = builder();
        Object rawPanicked = Wire.required(object, "panicked");
        builder.panicked(Wire.bool(rawPanicked, "TerminalLossCause.panicked"));
        Object rawSenderName = Wire.optional(object, "sender_name");
        if (!Wire.isMissing(rawSenderName)) {
            builder.senderName(Wire.string(rawSenderName, "TerminalLossCause.sender_name"));
        }
        Object rawSenderPid = Wire.optional(object, "sender_pid");
        if (!Wire.isMissing(rawSenderPid)) {
            builder.senderPid(rawSenderPid == null ? null : Wire.int64(rawSenderPid, "TerminalLossCause.sender_pid"));
        }
        Object rawSignal = Wire.optional(object, "signal");
        if (!Wire.isMissing(rawSignal)) {
            builder.signal(Wire.string(rawSignal, "TerminalLossCause.signal"));
        }
        List<String> known = List.of("panicked", "sender_name", "sender_pid", "signal");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "panicked", panicked);
        Wire.put(object, "sender_name", senderName);
        Wire.put(object, "sender_pid", senderPid);
        Wire.put(object, "signal", signal);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalLossCause that)) return false;
        return Objects.equals(panicked, that.panicked) && Objects.equals(senderName, that.senderName) && Objects.equals(senderPid, that.senderPid) && Objects.equals(signal, that.signal) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(panicked, senderName, senderPid, signal, additionalProperties); }

    @Override
    public String toString() { return "TerminalLossCause" + toWire(); }

    public static final class Builder {
        private Boolean panicked;
        private boolean panickedSet;
        private Field<String> senderName = Field.omitted();
        private Field<Long> senderPid = Field.omitted();
        private Field<String> signal = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder panicked(boolean value) {
            this.panicked = value;
            this.panickedSet = true;
            return this;
        }
        public Builder senderName(String value) {
            this.senderName = Field.of(value);
            return this;
        }
        public Builder senderPid(Long value) {
            this.senderPid = Field.ofNullable(value);
            return this;
        }
        public Builder signal(String value) {
            this.signal = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TerminalLossCause build() { return new TerminalLossCause(this); }
    }
}
