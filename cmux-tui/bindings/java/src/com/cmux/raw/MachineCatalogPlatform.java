// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineCatalogPlatform implements WireValue {
    private final Field<String> arch;
    private final Field<String> os;

    private MachineCatalogPlatform(Builder builder) {
        this.arch = builder.arch;
        this.os = builder.os;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> arch() { return arch; }
    public Field<String> os() { return os; }

    public static MachineCatalogPlatform fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineCatalogPlatform");
        Builder builder = builder();
        Object rawArch = Wire.optional(object, "arch");
        if (!Wire.isMissing(rawArch)) {
            builder.arch(rawArch == null ? null : Wire.string(rawArch, "MachineCatalogPlatform.arch"));
        }
        Object rawOs = Wire.optional(object, "os");
        if (!Wire.isMissing(rawOs)) {
            builder.os(rawOs == null ? null : Wire.string(rawOs, "MachineCatalogPlatform.os"));
        }
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
        if (!(other instanceof MachineCatalogPlatform that)) return false;
        return Objects.equals(arch, that.arch) && Objects.equals(os, that.os);
    }

    @Override
    public int hashCode() { return Objects.hash(arch, os); }

    @Override
    public String toString() { return "MachineCatalogPlatform" + toWire(); }

    public static final class Builder {
        private Field<String> arch = Field.omitted();
        private Field<String> os = Field.omitted();

        public Builder arch(String value) {
            this.arch = Field.ofNullable(value);
            return this;
        }
        public Builder os(String value) {
            this.os = Field.ofNullable(value);
            return this;
        }
        public MachineCatalogPlatform build() { return new MachineCatalogPlatform(this); }
    }
}
