// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpcKind implements WireValue {
    private final UInt64 bytes;
    private final String kind;
    private final UInt64 messages;

    private ServerStatsIpcKind(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.messagesSet) throw new IllegalArgumentException("messages is required");
        this.messages = Wire.nonNull(builder.messages, "messages");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public String kind() { return kind; }
    public UInt64 messages() { return messages; }

    public static ServerStatsIpcKind fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpcKind");
        Builder builder = builder();
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsIpcKind.bytes"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ServerStatsIpcKind.kind"));
        Object rawMessages = Wire.required(object, "messages");
        builder.messages(Wire.uint64(rawMessages, "ServerStatsIpcKind.messages"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "kind", kind);
        Wire.put(object, "messages", messages);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpcKind that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(kind, that.kind) && Objects.equals(messages, that.messages);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, kind, messages); }

    @Override
    public String toString() { return "ServerStatsIpcKind" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private String kind;
        private boolean kindSet;
        private UInt64 messages;
        private boolean messagesSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder messages(UInt64 value) {
            this.messages = value;
            this.messagesSet = true;
            return this;
        }
        public ServerStatsIpcKind build() { return new ServerStatsIpcKind(this); }
    }
}
