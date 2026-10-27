// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMethodLatency implements WireValue {
    private final String class_;
    private final ServerStatsPercentiles handlerUs;
    private final Integer id;
    private final ServerStatsPercentiles latencyUs;
    private final ServerStatsPercentiles lockWaitUs;
    private final String method;
    private final int traceId;

    private ServerStatsMethodLatency(Builder builder) {
        if (!builder.class_Set) throw new IllegalArgumentException("class is required");
        this.class_ = Wire.nonNull(builder.class_, "class");
        if (!builder.handlerUsSet) throw new IllegalArgumentException("handler_us is required");
        this.handlerUs = Wire.nonNull(builder.handlerUs, "handler_us");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = builder.id;
        if (!builder.latencyUsSet) throw new IllegalArgumentException("latency_us is required");
        this.latencyUs = Wire.nonNull(builder.latencyUs, "latency_us");
        if (!builder.lockWaitUsSet) throw new IllegalArgumentException("lock_wait_us is required");
        this.lockWaitUs = Wire.nonNull(builder.lockWaitUs, "lock_wait_us");
        if (!builder.methodSet) throw new IllegalArgumentException("method is required");
        this.method = Wire.nonNull(builder.method, "method");
        if (!builder.traceIdSet) throw new IllegalArgumentException("trace_id is required");
        this.traceId = builder.traceId;
    }

    public static Builder builder() { return new Builder(); }

    public String class_() { return class_; }
    public ServerStatsPercentiles handlerUs() { return handlerUs; }
    public Integer id() { return id; }
    public ServerStatsPercentiles latencyUs() { return latencyUs; }
    public ServerStatsPercentiles lockWaitUs() { return lockWaitUs; }
    public String method() { return method; }
    public int traceId() { return traceId; }

    public static ServerStatsMethodLatency fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMethodLatency");
        Builder builder = builder();
        Object rawClass = Wire.required(object, "class");
        builder.class_(Wire.string(rawClass, "ServerStatsMethodLatency.class"));
        Object rawHandlerUs = Wire.required(object, "handler_us");
        builder.handlerUs(ServerStatsPercentiles.fromWire(rawHandlerUs));
        Object rawId = Wire.required(object, "id");
        builder.id(rawId == null ? null : Wire.uint16(rawId, "ServerStatsMethodLatency.id"));
        Object rawLatencyUs = Wire.required(object, "latency_us");
        builder.latencyUs(ServerStatsPercentiles.fromWire(rawLatencyUs));
        Object rawLockWaitUs = Wire.required(object, "lock_wait_us");
        builder.lockWaitUs(ServerStatsPercentiles.fromWire(rawLockWaitUs));
        Object rawMethod = Wire.required(object, "method");
        builder.method(Wire.string(rawMethod, "ServerStatsMethodLatency.method"));
        Object rawTraceId = Wire.required(object, "trace_id");
        builder.traceId(Wire.uint16(rawTraceId, "ServerStatsMethodLatency.trace_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "class", class_);
        Wire.put(object, "handler_us", handlerUs);
        Wire.put(object, "id", id);
        Wire.put(object, "latency_us", latencyUs);
        Wire.put(object, "lock_wait_us", lockWaitUs);
        Wire.put(object, "method", method);
        Wire.put(object, "trace_id", traceId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMethodLatency that)) return false;
        return Objects.equals(class_, that.class_) && Objects.equals(handlerUs, that.handlerUs) && Objects.equals(id, that.id) && Objects.equals(latencyUs, that.latencyUs) && Objects.equals(lockWaitUs, that.lockWaitUs) && Objects.equals(method, that.method) && Objects.equals(traceId, that.traceId);
    }

    @Override
    public int hashCode() { return Objects.hash(class_, handlerUs, id, latencyUs, lockWaitUs, method, traceId); }

    @Override
    public String toString() { return "ServerStatsMethodLatency" + toWire(); }

    public static final class Builder {
        private String class_;
        private boolean class_Set;
        private ServerStatsPercentiles handlerUs;
        private boolean handlerUsSet;
        private Integer id;
        private boolean idSet;
        private ServerStatsPercentiles latencyUs;
        private boolean latencyUsSet;
        private ServerStatsPercentiles lockWaitUs;
        private boolean lockWaitUsSet;
        private String method;
        private boolean methodSet;
        private Integer traceId;
        private boolean traceIdSet;

        public Builder class_(String value) {
            this.class_ = value;
            this.class_Set = true;
            return this;
        }
        public Builder handlerUs(ServerStatsPercentiles value) {
            this.handlerUs = value;
            this.handlerUsSet = true;
            return this;
        }
        public Builder id(Integer value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder latencyUs(ServerStatsPercentiles value) {
            this.latencyUs = value;
            this.latencyUsSet = true;
            return this;
        }
        public Builder lockWaitUs(ServerStatsPercentiles value) {
            this.lockWaitUs = value;
            this.lockWaitUsSet = true;
            return this;
        }
        public Builder method(String value) {
            this.method = value;
            this.methodSet = true;
            return this;
        }
        public Builder traceId(int value) {
            this.traceId = value;
            this.traceIdSet = true;
            return this;
        }
        public ServerStatsMethodLatency build() { return new ServerStatsMethodLatency(this); }
    }
}
