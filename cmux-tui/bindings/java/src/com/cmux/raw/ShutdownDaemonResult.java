// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ShutdownDaemonResult implements WireValue {
    private final String generation;
    private final long pid;

    private ShutdownDaemonResult(Builder builder) {
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.pidSet) throw new IllegalArgumentException("pid is required");
        this.pid = builder.pid;
    }

    public static Builder builder() { return new Builder(); }

    public Boolean accepted() { return true; }
    public String generation() { return generation; }
    public long pid() { return pid; }

    public static ShutdownDaemonResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShutdownDaemonResult");
        Builder builder = builder();
        Object rawAccepted = Wire.required(object, "accepted");
        ProtocolSupport.literal(rawAccepted, true, "ShutdownDaemonResult.accepted");
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "ShutdownDaemonResult.generation"));
        Object rawPid = Wire.required(object, "pid");
        builder.pid(Wire.uint32(rawPid, "ShutdownDaemonResult.pid"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accepted", true);
        Wire.put(object, "generation", generation);
        Wire.put(object, "pid", pid);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShutdownDaemonResult that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(pid, that.pid);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, pid); }

    @Override
    public String toString() { return "ShutdownDaemonResult" + toWire(); }

    public static final class Builder {
        private String generation;
        private boolean generationSet;
        private Long pid;
        private boolean pidSet;

        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder pid(long value) {
            this.pid = value;
            this.pidSet = true;
            return this;
        }
        public ShutdownDaemonResult build() { return new ShutdownDaemonResult(this); }
    }
}
