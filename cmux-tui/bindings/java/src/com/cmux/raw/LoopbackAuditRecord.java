// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LoopbackAuditRecord implements WireValue {
    private final UInt64 atMs;
    private final UInt64 bytesFromTarget;
    private final UInt64 bytesToTarget;
    private final UInt64 client;
    private final UInt64 durationMs;
    private final String host;
    private final String outcome;
    private final int port;
    private final UInt64 stream;

    private LoopbackAuditRecord(Builder builder) {
        if (!builder.atMsSet) throw new IllegalArgumentException("at_ms is required");
        this.atMs = Wire.nonNull(builder.atMs, "at_ms");
        if (!builder.bytesFromTargetSet) throw new IllegalArgumentException("bytes_from_target is required");
        this.bytesFromTarget = Wire.nonNull(builder.bytesFromTarget, "bytes_from_target");
        if (!builder.bytesToTargetSet) throw new IllegalArgumentException("bytes_to_target is required");
        this.bytesToTarget = Wire.nonNull(builder.bytesToTarget, "bytes_to_target");
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.durationMsSet) throw new IllegalArgumentException("duration_ms is required");
        this.durationMs = Wire.nonNull(builder.durationMs, "duration_ms");
        if (!builder.hostSet) throw new IllegalArgumentException("host is required");
        this.host = Wire.nonNull(builder.host, "host");
        if (!builder.outcomeSet) throw new IllegalArgumentException("outcome is required");
        this.outcome = Wire.nonNull(builder.outcome, "outcome");
        if (!builder.portSet) throw new IllegalArgumentException("port is required");
        this.port = builder.port;
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = Wire.nonNull(builder.stream, "stream");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 atMs() { return atMs; }
    public UInt64 bytesFromTarget() { return bytesFromTarget; }
    public UInt64 bytesToTarget() { return bytesToTarget; }
    public UInt64 client() { return client; }
    public UInt64 durationMs() { return durationMs; }
    public String host() { return host; }
    public String outcome() { return outcome; }
    public int port() { return port; }
    public UInt64 stream() { return stream; }

    public static LoopbackAuditRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackAuditRecord");
        Builder builder = builder();
        Object rawAtMs = Wire.required(object, "at_ms");
        builder.atMs(Wire.uint64(rawAtMs, "LoopbackAuditRecord.at_ms"));
        Object rawBytesFromTarget = Wire.required(object, "bytes_from_target");
        builder.bytesFromTarget(Wire.uint64(rawBytesFromTarget, "LoopbackAuditRecord.bytes_from_target"));
        Object rawBytesToTarget = Wire.required(object, "bytes_to_target");
        builder.bytesToTarget(Wire.uint64(rawBytesToTarget, "LoopbackAuditRecord.bytes_to_target"));
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "LoopbackAuditRecord.client"));
        Object rawDurationMs = Wire.required(object, "duration_ms");
        builder.durationMs(Wire.uint64(rawDurationMs, "LoopbackAuditRecord.duration_ms"));
        Object rawHost = Wire.required(object, "host");
        builder.host(Wire.string(rawHost, "LoopbackAuditRecord.host"));
        Object rawOutcome = Wire.required(object, "outcome");
        builder.outcome(Wire.string(rawOutcome, "LoopbackAuditRecord.outcome"));
        Object rawPort = Wire.required(object, "port");
        builder.port(Wire.uint16(rawPort, "LoopbackAuditRecord.port"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint64(rawStream, "LoopbackAuditRecord.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "at_ms", atMs);
        Wire.put(object, "bytes_from_target", bytesFromTarget);
        Wire.put(object, "bytes_to_target", bytesToTarget);
        Wire.put(object, "client", client);
        Wire.put(object, "duration_ms", durationMs);
        Wire.put(object, "host", host);
        Wire.put(object, "outcome", outcome);
        Wire.put(object, "port", port);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackAuditRecord that)) return false;
        return Objects.equals(atMs, that.atMs) && Objects.equals(bytesFromTarget, that.bytesFromTarget) && Objects.equals(bytesToTarget, that.bytesToTarget) && Objects.equals(client, that.client) && Objects.equals(durationMs, that.durationMs) && Objects.equals(host, that.host) && Objects.equals(outcome, that.outcome) && Objects.equals(port, that.port) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(atMs, bytesFromTarget, bytesToTarget, client, durationMs, host, outcome, port, stream); }

    @Override
    public String toString() { return "LoopbackAuditRecord" + toWire(); }

    public static final class Builder {
        private UInt64 atMs;
        private boolean atMsSet;
        private UInt64 bytesFromTarget;
        private boolean bytesFromTargetSet;
        private UInt64 bytesToTarget;
        private boolean bytesToTargetSet;
        private UInt64 client;
        private boolean clientSet;
        private UInt64 durationMs;
        private boolean durationMsSet;
        private String host;
        private boolean hostSet;
        private String outcome;
        private boolean outcomeSet;
        private Integer port;
        private boolean portSet;
        private UInt64 stream;
        private boolean streamSet;

        public Builder atMs(UInt64 value) {
            this.atMs = value;
            this.atMsSet = true;
            return this;
        }
        public Builder bytesFromTarget(UInt64 value) {
            this.bytesFromTarget = value;
            this.bytesFromTargetSet = true;
            return this;
        }
        public Builder bytesToTarget(UInt64 value) {
            this.bytesToTarget = value;
            this.bytesToTargetSet = true;
            return this;
        }
        public Builder client(UInt64 value) {
            this.client = value;
            this.clientSet = true;
            return this;
        }
        public Builder durationMs(UInt64 value) {
            this.durationMs = value;
            this.durationMsSet = true;
            return this;
        }
        public Builder host(String value) {
            this.host = value;
            this.hostSet = true;
            return this;
        }
        public Builder outcome(String value) {
            this.outcome = value;
            this.outcomeSet = true;
            return this;
        }
        public Builder port(int value) {
            this.port = value;
            this.portSet = true;
            return this;
        }
        public Builder stream(UInt64 value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public LoopbackAuditRecord build() { return new LoopbackAuditRecord(this); }
    }
}
