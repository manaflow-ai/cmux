// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsSlowRequest implements WireValue {
    private final UInt64 busyMs;
    private final UInt64 client;
    private final UInt64 durationMs;
    private final String method;
    private final List<ServerStatsSlowRequestFrame> stack;
    private final String stackError;
    private final boolean stackTruncated;
    private final UInt64 startedMs;

    private ServerStatsSlowRequest(Builder builder) {
        if (!builder.busyMsSet) throw new IllegalArgumentException("busy_ms is required");
        this.busyMs = Wire.nonNull(builder.busyMs, "busy_ms");
        if (!builder.clientSet) throw new IllegalArgumentException("client is required");
        this.client = Wire.nonNull(builder.client, "client");
        if (!builder.durationMsSet) throw new IllegalArgumentException("duration_ms is required");
        this.durationMs = builder.durationMs;
        if (!builder.methodSet) throw new IllegalArgumentException("method is required");
        this.method = Wire.nonNull(builder.method, "method");
        if (!builder.stackSet) throw new IllegalArgumentException("stack is required");
        this.stack = List.copyOf(Wire.nonNull(builder.stack, "stack"));
        if (!builder.stackErrorSet) throw new IllegalArgumentException("stack_error is required");
        this.stackError = builder.stackError;
        if (!builder.stackTruncatedSet) throw new IllegalArgumentException("stack_truncated is required");
        this.stackTruncated = builder.stackTruncated;
        if (!builder.startedMsSet) throw new IllegalArgumentException("started_ms is required");
        this.startedMs = Wire.nonNull(builder.startedMs, "started_ms");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 busyMs() { return busyMs; }
    public UInt64 client() { return client; }
    public UInt64 durationMs() { return durationMs; }
    public String method() { return method; }
    public List<ServerStatsSlowRequestFrame> stack() { return stack; }
    public String stackError() { return stackError; }
    public boolean stackTruncated() { return stackTruncated; }
    public UInt64 startedMs() { return startedMs; }

    public static ServerStatsSlowRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsSlowRequest");
        Builder builder = builder();
        Object rawBusyMs = Wire.required(object, "busy_ms");
        builder.busyMs(Wire.uint64(rawBusyMs, "ServerStatsSlowRequest.busy_ms"));
        Object rawClient = Wire.required(object, "client");
        builder.client(Wire.uint64(rawClient, "ServerStatsSlowRequest.client"));
        Object rawDurationMs = Wire.required(object, "duration_ms");
        builder.durationMs(rawDurationMs == null ? null : Wire.uint64(rawDurationMs, "ServerStatsSlowRequest.duration_ms"));
        Object rawMethod = Wire.required(object, "method");
        builder.method(Wire.string(rawMethod, "ServerStatsSlowRequest.method"));
        Object rawStack = Wire.required(object, "stack");
        builder.stack(Wire.array(rawStack, "ServerStatsSlowRequest.stack", item -> ServerStatsSlowRequestFrame.fromWire(item)));
        Object rawStackError = Wire.required(object, "stack_error");
        builder.stackError(rawStackError == null ? null : Wire.string(rawStackError, "ServerStatsSlowRequest.stack_error"));
        Object rawStackTruncated = Wire.required(object, "stack_truncated");
        builder.stackTruncated(Wire.bool(rawStackTruncated, "ServerStatsSlowRequest.stack_truncated"));
        Object rawStartedMs = Wire.required(object, "started_ms");
        builder.startedMs(Wire.uint64(rawStartedMs, "ServerStatsSlowRequest.started_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "busy_ms", busyMs);
        Wire.put(object, "client", client);
        Wire.put(object, "duration_ms", durationMs);
        Wire.put(object, "method", method);
        Wire.put(object, "stack", stack);
        Wire.put(object, "stack_error", stackError);
        Wire.put(object, "stack_truncated", stackTruncated);
        Wire.put(object, "started_ms", startedMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsSlowRequest that)) return false;
        return Objects.equals(busyMs, that.busyMs) && Objects.equals(client, that.client) && Objects.equals(durationMs, that.durationMs) && Objects.equals(method, that.method) && Objects.equals(stack, that.stack) && Objects.equals(stackError, that.stackError) && Objects.equals(stackTruncated, that.stackTruncated) && Objects.equals(startedMs, that.startedMs);
    }

    @Override
    public int hashCode() { return Objects.hash(busyMs, client, durationMs, method, stack, stackError, stackTruncated, startedMs); }

    @Override
    public String toString() { return "ServerStatsSlowRequest" + toWire(); }

    public static final class Builder {
        private UInt64 busyMs;
        private boolean busyMsSet;
        private UInt64 client;
        private boolean clientSet;
        private UInt64 durationMs;
        private boolean durationMsSet;
        private String method;
        private boolean methodSet;
        private List<ServerStatsSlowRequestFrame> stack;
        private boolean stackSet;
        private String stackError;
        private boolean stackErrorSet;
        private Boolean stackTruncated;
        private boolean stackTruncatedSet;
        private UInt64 startedMs;
        private boolean startedMsSet;

        public Builder busyMs(UInt64 value) {
            this.busyMs = value;
            this.busyMsSet = true;
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
        public Builder method(String value) {
            this.method = value;
            this.methodSet = true;
            return this;
        }
        public Builder stack(List<ServerStatsSlowRequestFrame> value) {
            this.stack = value;
            this.stackSet = true;
            return this;
        }
        public Builder stackError(String value) {
            this.stackError = value;
            this.stackErrorSet = true;
            return this;
        }
        public Builder stackTruncated(boolean value) {
            this.stackTruncated = value;
            this.stackTruncatedSet = true;
            return this;
        }
        public Builder startedMs(UInt64 value) {
            this.startedMs = value;
            this.startedMsSet = true;
            return this;
        }
        public ServerStatsSlowRequest build() { return new ServerStatsSlowRequest(this); }
    }
}
