// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalResourcesResult implements WireValue {
    private final List<UInt64> missing;
    private final UInt64 sampledAtNs;
    private final List<TerminalResources> terminals;

    private TerminalResourcesResult(Builder builder) {
        if (!builder.missingSet) throw new IllegalArgumentException("missing is required");
        this.missing = List.copyOf(Wire.nonNull(builder.missing, "missing"));
        if (!builder.sampledAtNsSet) throw new IllegalArgumentException("sampled_at_ns is required");
        this.sampledAtNs = Wire.nonNull(builder.sampledAtNs, "sampled_at_ns");
        if (!builder.terminalsSet) throw new IllegalArgumentException("terminals is required");
        this.terminals = List.copyOf(Wire.nonNull(builder.terminals, "terminals"));
    }

    public static Builder builder() { return new Builder(); }

    public List<UInt64> missing() { return missing; }
    public UInt64 sampledAtNs() { return sampledAtNs; }
    public List<TerminalResources> terminals() { return terminals; }

    public static TerminalResourcesResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalResourcesResult");
        Builder builder = builder();
        Object rawMissing = Wire.required(object, "missing");
        builder.missing(Wire.array(rawMissing, "TerminalResourcesResult.missing", item -> Wire.uint64(item, "TerminalResourcesResult.missing item")));
        Object rawSampledAtNs = Wire.required(object, "sampled_at_ns");
        builder.sampledAtNs(Wire.uint64(rawSampledAtNs, "TerminalResourcesResult.sampled_at_ns"));
        Object rawTerminals = Wire.required(object, "terminals");
        builder.terminals(Wire.array(rawTerminals, "TerminalResourcesResult.terminals", item -> TerminalResources.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "missing", missing);
        Wire.put(object, "sampled_at_ns", sampledAtNs);
        Wire.put(object, "terminals", terminals);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalResourcesResult that)) return false;
        return Objects.equals(missing, that.missing) && Objects.equals(sampledAtNs, that.sampledAtNs) && Objects.equals(terminals, that.terminals);
    }

    @Override
    public int hashCode() { return Objects.hash(missing, sampledAtNs, terminals); }

    @Override
    public String toString() { return "TerminalResourcesResult" + toWire(); }

    public static final class Builder {
        private List<UInt64> missing;
        private boolean missingSet;
        private UInt64 sampledAtNs;
        private boolean sampledAtNsSet;
        private List<TerminalResources> terminals;
        private boolean terminalsSet;

        public Builder missing(List<UInt64> value) {
            this.missing = value;
            this.missingSet = true;
            return this;
        }
        public Builder sampledAtNs(UInt64 value) {
            this.sampledAtNs = value;
            this.sampledAtNsSet = true;
            return this;
        }
        public Builder terminals(List<TerminalResources> value) {
            this.terminals = value;
            this.terminalsSet = true;
            return this;
        }
        public TerminalResourcesResult build() { return new TerminalResourcesResult(this); }
    }
}
