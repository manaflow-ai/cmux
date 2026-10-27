// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcWrites implements WireValue {
    private final UInt64 messages;
    private final UInt64 stalls;
    private final UInt64 syscalls;
    private final double syscallsPerMessage;

    private ServerStatsIpcWrites(Builder builder) {
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = Wire.nonNull(builder.messages, "messages");
        if (!builder.stallsSet) throw new IllegalArgumentException("stalls is required");
        this.stalls = Wire.nonNull(builder.stalls, "stalls");
        if (!builder.syscallsSet) throw new IllegalArgumentException("syscalls is required");
        this.syscalls = Wire.nonNull(builder.syscalls, "syscalls");
        if (!builder.syscallsPerMessageSet) throw new IllegalArgumentException("syscalls_per_message is required");
        this.syscallsPerMessage = builder.syscallsPerMessage;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 messages() { return messages; }
    public UInt64 stalls() { return stalls; }
    public UInt64 syscalls() { return syscalls; }
    public double syscallsPerMessage() { return syscallsPerMessage; }

    public static ServerStatsIpcWrites fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcWrites");
        Builder builder = builder();
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.uint64(rawMessages, "ServerStatsIpcWrites.messages"));
        Object rawStalls = Wire.required(object, "stalls");
        builder.stalls(Wire.uint64(rawStalls, "ServerStatsIpcWrites.stalls"));
        Object rawSyscalls = Wire.required(object, "syscalls");
        builder.syscalls(Wire.uint64(rawSyscalls, "ServerStatsIpcWrites.syscalls"));
        Object rawSyscallsPerMessage = Wire.required(object, "syscalls_per_message");
        builder.syscallsPerMessage(Wire.float64(rawSyscallsPerMessage, "ServerStatsIpcWrites.syscalls_per_message"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "messages", messages);
        Wire.put(object, "stalls", stalls);
        Wire.put(object, "syscalls", syscalls);
        Wire.put(object, "syscalls_per_message", syscallsPerMessage);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcWrites that)) return false;
        return Objects.equals(messages, that.messages) && Objects.equals(stalls, that.stalls) && Objects.equals(syscalls, that.syscalls) && Objects.equals(syscallsPerMessage, that.syscallsPerMessage);
    }

    @Override
    public int hashCode() { return Objects.hash(messages, stalls, syscalls, syscallsPerMessage); }

    @Override
    public String toString() { return "ServerStatsIpcWrites" + toWire(); }

    public static final class Builder {
        private UInt64 messages;
        private boolean messagesSet;
        private UInt64 stalls;
        private boolean stallsSet;
        private UInt64 syscalls;
        private boolean syscallsSet;
        private Double syscallsPerMessage;
        private boolean syscallsPerMessageSet;

        public Builder messages(UInt64 value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public Builder stalls(UInt64 value) {
            this.stalls = value;
            this.stallsSet = true;
            return this;
        }
        public Builder syscalls(UInt64 value) {
            this.syscalls = value;
            this.syscallsSet = true;
            return this;
        }
        public Builder syscallsPerMessage(double value) {
            this.syscallsPerMessage = value;
            this.syscallsPerMessageSet = true;
            return this;
        }
        public ServerStatsIpcWrites build() { return new ServerStatsIpcWrites(this); }
    }
}
