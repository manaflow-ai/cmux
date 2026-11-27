// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachinePlatform implements WireValue {
    private final String arch;
    private final String os;

    private MachinePlatform(Builder builder) {
        if (!builder.archSet) throw new IllegalArgumentException("arch is required");
        this.arch = Wire.nonNull(builder.arch, "arch");
        if (!builder.osSet) throw new IllegalArgumentException("os is required");
        this.os = Wire.nonNull(builder.os, "os");
    }

    public static Builder builder() { return new Builder(); }

    public String arch() { return arch; }
    public String os() { return os; }

    public static MachinePlatform fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachinePlatform");
        Builder builder = builder();
        Object rawArch = Wire.required(object, "arch");
        builder.arch(Wire.string(rawArch, "MachinePlatform.arch"));
        Object rawOs = Wire.required(object, "os");
        builder.os(Wire.string(rawOs, "MachinePlatform.os"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "arch", arch);
        Wire.put(object, "os", os);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachinePlatform that)) return false;
        return Objects.equals(arch, that.arch) && Objects.equals(os, that.os);
    }

    @Override
    public int hashCode() { return Objects.hash(arch, os); }

    @Override
    public String toString() { return "MachinePlatform" + toWire(); }

    public static final class Builder {
        private String arch;
        private boolean archSet;
        private String os;
        private boolean osSet;

        public Builder arch(String value) {
            this.arch = value;
            this.archSet = true;
            return this;
        }
        public Builder os(String value) {
            this.os = value;
            this.osSet = true;
            return this;
        }
        public MachinePlatform build() { return new MachinePlatform(this); }
    }
}
