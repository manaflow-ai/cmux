// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LoopbackStatusResult implements WireValue {
    private final List<LoopbackAuditRecord> audit;
    private final UInt64 clientStreams;
    private final boolean enabled;
    private final LoopbackLimits limits;
    private final UInt64 openStreams;
    private final UInt64 opened;
    private final UInt64 refused;

    private LoopbackStatusResult(Builder builder) {
        if (!builder.auditSet) throw new IllegalArgumentException("audit is required");
        this.audit = List.copyOf(Wire.nonNull(builder.audit, "audit"));
        if (!builder.clientStreamsSet) throw new IllegalArgumentException("client_streams is required");
        this.clientStreams = Wire.nonNull(builder.clientStreams, "client_streams");
        if (!builder.enabledSet) throw new IllegalArgumentException("enabled is required");
        this.enabled = builder.enabled;
        if (!builder.limitsSet) throw new IllegalArgumentException("limits is required");
        this.limits = Wire.nonNull(builder.limits, "limits");
        if (!builder.openStreamsSet) throw new IllegalArgumentException("open_streams is required");
        this.openStreams = Wire.nonNull(builder.openStreams, "open_streams");
        if (!builder.openedSet) throw new IllegalArgumentException("opened is required");
        this.opened = Wire.nonNull(builder.opened, "opened");
        if (!builder.refusedSet) throw new IllegalArgumentException("refused is required");
        this.refused = Wire.nonNull(builder.refused, "refused");
    }

    public static Builder builder() { return new Builder(); }

    public List<LoopbackAuditRecord> audit() { return audit; }
    public UInt64 clientStreams() { return clientStreams; }
    public boolean enabled() { return enabled; }
    public LoopbackLimits limits() { return limits; }
    public UInt64 openStreams() { return openStreams; }
    public UInt64 opened() { return opened; }
    public UInt64 refused() { return refused; }

    public static LoopbackStatusResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LoopbackStatusResult");
        Builder builder = builder();
        Object rawAudit = Wire.required(object, "audit");
        builder.audit(Wire.array(rawAudit, "LoopbackStatusResult.audit", item -> LoopbackAuditRecord.fromWire(item)));
        Object rawClientStreams = Wire.required(object, "client_streams");
        builder.clientStreams(Wire.uint64(rawClientStreams, "LoopbackStatusResult.client_streams"));
        Object rawEnabled = Wire.required(object, "enabled");
        builder.enabled(Wire.bool(rawEnabled, "LoopbackStatusResult.enabled"));
        Object rawLimits = Wire.required(object, "limits");
        builder.limits(LoopbackLimits.fromWire(rawLimits));
        Object rawOpenStreams = Wire.required(object, "open_streams");
        builder.openStreams(Wire.uint64(rawOpenStreams, "LoopbackStatusResult.open_streams"));
        Object rawOpened = Wire.required(object, "opened");
        builder.opened(Wire.uint64(rawOpened, "LoopbackStatusResult.opened"));
        Object rawRefused = Wire.required(object, "refused");
        builder.refused(Wire.uint64(rawRefused, "LoopbackStatusResult.refused"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "audit", audit);
        Wire.put(object, "client_streams", clientStreams);
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "limits", limits);
        Wire.put(object, "open_streams", openStreams);
        Wire.put(object, "opened", opened);
        Wire.put(object, "refused", refused);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LoopbackStatusResult that)) return false;
        return Objects.equals(audit, that.audit) && Objects.equals(clientStreams, that.clientStreams) && Objects.equals(enabled, that.enabled) && Objects.equals(limits, that.limits) && Objects.equals(openStreams, that.openStreams) && Objects.equals(opened, that.opened) && Objects.equals(refused, that.refused);
    }

    @Override
    public int hashCode() { return Objects.hash(audit, clientStreams, enabled, limits, openStreams, opened, refused); }

    @Override
    public String toString() { return "LoopbackStatusResult" + toWire(); }

    public static final class Builder {
        private List<LoopbackAuditRecord> audit;
        private boolean auditSet;
        private UInt64 clientStreams;
        private boolean clientStreamsSet;
        private Boolean enabled;
        private boolean enabledSet;
        private LoopbackLimits limits;
        private boolean limitsSet;
        private UInt64 openStreams;
        private boolean openStreamsSet;
        private UInt64 opened;
        private boolean openedSet;
        private UInt64 refused;
        private boolean refusedSet;

        public Builder audit(List<LoopbackAuditRecord> value) {
            this.audit = value;
            this.auditSet = true;
            return this;
        }
        public Builder clientStreams(UInt64 value) {
            this.clientStreams = value;
            this.clientStreamsSet = true;
            return this;
        }
        public Builder enabled(boolean value) {
            this.enabled = value;
            this.enabledSet = true;
            return this;
        }
        public Builder limits(LoopbackLimits value) {
            this.limits = value;
            this.limitsSet = true;
            return this;
        }
        public Builder openStreams(UInt64 value) {
            this.openStreams = value;
            this.openStreamsSet = true;
            return this;
        }
        public Builder opened(UInt64 value) {
            this.opened = value;
            this.openedSet = true;
            return this;
        }
        public Builder refused(UInt64 value) {
            this.refused = value;
            this.refusedSet = true;
            return this;
        }
        public LoopbackStatusResult build() { return new LoopbackStatusResult(this); }
    }
}
