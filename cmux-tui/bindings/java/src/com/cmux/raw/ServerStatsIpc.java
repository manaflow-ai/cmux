// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsIpc implements WireValue {
    private final UInt64 badMessage;
    private final ServerStatsIpcParses parses;
    private final List<ServerStatsIpcKind> received;
    private final List<ServerStatsIpcKind> sent;
    private final ServerStatsHistogram sequenceDepth;
    private final ServerStatsIpcStreams streams;
    private final ServerStatsIpcWrites writes;

    private ServerStatsIpc(Builder builder) {
        if (!builder.badMessageSet) throw new IllegalArgumentException("bad_message is required");
        this.badMessage = Wire.nonNull(builder.badMessage, "bad_message");
        if (!builder.parsesSet) throw new IllegalArgumentException("parses is required");
        this.parses = Wire.nonNull(builder.parses, "parses");
        if (!builder.receivedSet) throw new IllegalArgumentException("received is required");
        this.received = List.copyOf(Wire.nonNull(builder.received, "received"));
        if (!builder.sentSet) throw new IllegalArgumentException("sent is required");
        this.sent = List.copyOf(Wire.nonNull(builder.sent, "sent"));
        if (!builder.sequenceDepthSet) throw new IllegalArgumentException("sequence_depth is required");
        this.sequenceDepth = Wire.nonNull(builder.sequenceDepth, "sequence_depth");
        if (!builder.streamsSet) throw new IllegalArgumentException("streams is required");
        this.streams = Wire.nonNull(builder.streams, "streams");
        if (!builder.writesSet) throw new IllegalArgumentException("writes is required");
        this.writes = Wire.nonNull(builder.writes, "writes");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 badMessage() { return badMessage; }
    public ServerStatsIpcParses parses() { return parses; }
    public List<ServerStatsIpcKind> received() { return received; }
    public List<ServerStatsIpcKind> sent() { return sent; }
    public ServerStatsHistogram sequenceDepth() { return sequenceDepth; }
    public ServerStatsIpcStreams streams() { return streams; }
    public ServerStatsIpcWrites writes() { return writes; }

    public static ServerStatsIpc fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsIpc");
        Builder builder = builder();
        Object rawBadMessage = Wire.required(object, "bad_message");
        builder.badMessage(Wire.uint64(rawBadMessage, "ServerStatsIpc.bad_message"));
        Object rawParses = Wire.required(object, "parses");
        builder.parses(ServerStatsIpcParses.fromWire(rawParses));
        Object rawReceived = Wire.required(object, "received");
        builder.received(Wire.array(rawReceived, "ServerStatsIpc.received", item -> ServerStatsIpcKind.fromWire(item)));
        Object rawSent = Wire.required(object, "sent");
        builder.sent(Wire.array(rawSent, "ServerStatsIpc.sent", item -> ServerStatsIpcKind.fromWire(item)));
        Object rawSequenceDepth = Wire.required(object, "sequence_depth");
        builder.sequenceDepth(ServerStatsHistogram.fromWire(rawSequenceDepth));
        Object rawStreams = Wire.required(object, "streams");
        builder.streams(ServerStatsIpcStreams.fromWire(rawStreams));
        Object rawWrites = Wire.required(object, "writes");
        builder.writes(ServerStatsIpcWrites.fromWire(rawWrites));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bad_message", badMessage);
        Wire.put(object, "parses", parses);
        Wire.put(object, "received", received);
        Wire.put(object, "sent", sent);
        Wire.put(object, "sequence_depth", sequenceDepth);
        Wire.put(object, "streams", streams);
        Wire.put(object, "writes", writes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsIpc that)) return false;
        return Objects.equals(badMessage, that.badMessage) && Objects.equals(parses, that.parses) && Objects.equals(received, that.received) && Objects.equals(sent, that.sent) && Objects.equals(sequenceDepth, that.sequenceDepth) && Objects.equals(streams, that.streams) && Objects.equals(writes, that.writes);
    }

    @Override
    public int hashCode() { return Objects.hash(badMessage, parses, received, sent, sequenceDepth, streams, writes); }

    @Override
    public String toString() { return "ServerStatsIpc" + toWire(); }

    public static final class Builder {
        private UInt64 badMessage;
        private boolean badMessageSet;
        private ServerStatsIpcParses parses;
        private boolean parsesSet;
        private List<ServerStatsIpcKind> received;
        private boolean receivedSet;
        private List<ServerStatsIpcKind> sent;
        private boolean sentSet;
        private ServerStatsHistogram sequenceDepth;
        private boolean sequenceDepthSet;
        private ServerStatsIpcStreams streams;
        private boolean streamsSet;
        private ServerStatsIpcWrites writes;
        private boolean writesSet;

        public Builder badMessage(UInt64 value) {
            this.badMessage = value;
            this.badMessageSet = true;
            return this;
        }
        public Builder parses(ServerStatsIpcParses value) {
            this.parses = value;
            this.parsesSet = true;
            return this;
        }
        public Builder received(List<ServerStatsIpcKind> value) {
            this.received = value;
            this.receivedSet = true;
            return this;
        }
        public Builder sent(List<ServerStatsIpcKind> value) {
            this.sent = value;
            this.sentSet = true;
            return this;
        }
        public Builder sequenceDepth(ServerStatsHistogram value) {
            this.sequenceDepth = value;
            this.sequenceDepthSet = true;
            return this;
        }
        public Builder streams(ServerStatsIpcStreams value) {
            this.streams = value;
            this.streamsSet = true;
            return this;
        }
        public Builder writes(ServerStatsIpcWrites value) {
            this.writes = value;
            this.writesSet = true;
            return this;
        }
        public ServerStatsIpc build() { return new ServerStatsIpc(this); }
    }
}
