// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsTerminalModels implements WireValue {
    private final UInt64 daemon;
    private final UInt64 exited;
    private final UInt64 holder;
    private final UInt64 holderStartFailures;
    private final UInt64 hostAdopted;
    private final UInt64 hostLaunched;
    private final Field<String> lastHolderStartFailure;
    private final String model;
    private final String modelReason;

    private ServerStatsTerminalModels(Builder builder) {
        if (!builder.daemonSet) throw new IllegalArgumentException("daemon is required");
        this.daemon = Wire.nonNull(builder.daemon, "daemon");
        if (!builder.exitedSet) throw new IllegalArgumentException("exited is required");
        this.exited = Wire.nonNull(builder.exited, "exited");
        if (!builder.holderSet) throw new IllegalArgumentException("holder is required");
        this.holder = Wire.nonNull(builder.holder, "holder");
        if (!builder.holderStartFailuresSet) throw new IllegalArgumentException("holder_start_failures is required");
        this.holderStartFailures = Wire.nonNull(builder.holderStartFailures, "holder_start_failures");
        if (!builder.hostAdoptedSet) throw new IllegalArgumentException("host_adopted is required");
        this.hostAdopted = Wire.nonNull(builder.hostAdopted, "host_adopted");
        if (!builder.hostLaunchedSet) throw new IllegalArgumentException("host_launched is required");
        this.hostLaunched = Wire.nonNull(builder.hostLaunched, "host_launched");
        this.lastHolderStartFailure = builder.lastHolderStartFailure;
        if (!builder.modelSet) throw new IllegalArgumentException("model is required");
        this.model = Wire.nonNull(builder.model, "model");
        if (!builder.modelReasonSet) throw new IllegalArgumentException("model_reason is required");
        this.modelReason = Wire.nonNull(builder.modelReason, "model_reason");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 daemon() { return daemon; }
    public UInt64 exited() { return exited; }
    public UInt64 holder() { return holder; }
    public UInt64 holderStartFailures() { return holderStartFailures; }
    public UInt64 hostAdopted() { return hostAdopted; }
    public UInt64 hostLaunched() { return hostLaunched; }
    public Field<String> lastHolderStartFailure() { return lastHolderStartFailure; }
    public String model() { return model; }
    public String modelReason() { return modelReason; }

    public static ServerStatsTerminalModels fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsTerminalModels");
        Builder builder = builder();
        Object rawDaemon = Wire.required(object, "daemon");
        builder.daemon(Wire.uint64(rawDaemon, "ServerStatsTerminalModels.daemon"));
        Object rawExited = Wire.required(object, "exited");
        builder.exited(Wire.uint64(rawExited, "ServerStatsTerminalModels.exited"));
        Object rawHolder = Wire.required(object, "holder");
        builder.holder(Wire.uint64(rawHolder, "ServerStatsTerminalModels.holder"));
        Object rawHolderStartFailures = Wire.required(object, "holder_start_failures");
        builder.holderStartFailures(Wire.uint64(rawHolderStartFailures, "ServerStatsTerminalModels.holder_start_failures"));
        Object rawHostAdopted = Wire.required(object, "host_adopted");
        builder.hostAdopted(Wire.uint64(rawHostAdopted, "ServerStatsTerminalModels.host_adopted"));
        Object rawHostLaunched = Wire.required(object, "host_launched");
        builder.hostLaunched(Wire.uint64(rawHostLaunched, "ServerStatsTerminalModels.host_launched"));
        Object rawLastHolderStartFailure = Wire.optional(object, "last_holder_start_failure");
        if (!Wire.isMissing(rawLastHolderStartFailure)) {
            builder.lastHolderStartFailure(Wire.string(rawLastHolderStartFailure, "ServerStatsTerminalModels.last_holder_start_failure"));
        }
        Object rawModel = Wire.required(object, "model");
        builder.model(Wire.string(rawModel, "ServerStatsTerminalModels.model"));
        Object rawModelReason = Wire.required(object, "model_reason");
        builder.modelReason(Wire.string(rawModelReason, "ServerStatsTerminalModels.model_reason"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "daemon", daemon);
        Wire.put(object, "exited", exited);
        Wire.put(object, "holder", holder);
        Wire.put(object, "holder_start_failures", holderStartFailures);
        Wire.put(object, "host_adopted", hostAdopted);
        Wire.put(object, "host_launched", hostLaunched);
        Wire.put(object, "last_holder_start_failure", lastHolderStartFailure);
        Wire.put(object, "model", model);
        Wire.put(object, "model_reason", modelReason);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsTerminalModels that)) return false;
        return Objects.equals(daemon, that.daemon) && Objects.equals(exited, that.exited) && Objects.equals(holder, that.holder) && Objects.equals(holderStartFailures, that.holderStartFailures) && Objects.equals(hostAdopted, that.hostAdopted) && Objects.equals(hostLaunched, that.hostLaunched) && Objects.equals(lastHolderStartFailure, that.lastHolderStartFailure) && Objects.equals(model, that.model) && Objects.equals(modelReason, that.modelReason);
    }

    @Override
    public int hashCode() { return Objects.hash(daemon, exited, holder, holderStartFailures, hostAdopted, hostLaunched, lastHolderStartFailure, model, modelReason); }

    @Override
    public String toString() { return "ServerStatsTerminalModels" + toWire(); }

    public static final class Builder {
        private UInt64 daemon;
        private boolean daemonSet;
        private UInt64 exited;
        private boolean exitedSet;
        private UInt64 holder;
        private boolean holderSet;
        private UInt64 holderStartFailures;
        private boolean holderStartFailuresSet;
        private UInt64 hostAdopted;
        private boolean hostAdoptedSet;
        private UInt64 hostLaunched;
        private boolean hostLaunchedSet;
        private Field<String> lastHolderStartFailure = Field.omitted();
        private String model;
        private boolean modelSet;
        private String modelReason;
        private boolean modelReasonSet;

        public Builder daemon(UInt64 value) {
            this.daemon = value;
            this.daemonSet = true;
            return this;
        }
        public Builder exited(UInt64 value) {
            this.exited = value;
            this.exitedSet = true;
            return this;
        }
        public Builder holder(UInt64 value) {
            this.holder = value;
            this.holderSet = true;
            return this;
        }
        public Builder holderStartFailures(UInt64 value) {
            this.holderStartFailures = value;
            this.holderStartFailuresSet = true;
            return this;
        }
        public Builder hostAdopted(UInt64 value) {
            this.hostAdopted = value;
            this.hostAdoptedSet = true;
            return this;
        }
        public Builder hostLaunched(UInt64 value) {
            this.hostLaunched = value;
            this.hostLaunchedSet = true;
            return this;
        }
        public Builder lastHolderStartFailure(String value) {
            this.lastHolderStartFailure = Field.of(value);
            return this;
        }
        public Builder model(String value) {
            this.model = value;
            this.modelSet = true;
            return this;
        }
        public Builder modelReason(String value) {
            this.modelReason = value;
            this.modelReasonSet = true;
            return this;
        }
        public ServerStatsTerminalModels build() { return new ServerStatsTerminalModels(this); }
    }
}
