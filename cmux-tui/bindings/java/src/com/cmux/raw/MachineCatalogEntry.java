// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineCatalogEntry implements WireValue {
    private final Field<List<String>> capabilities;
    private final String id;
    private final String name;
    private final MachineCatalogOrigin origin;
    private final Field<MachineCatalogPlatform> platform;
    private final MachineCatalogStatus status;

    private MachineCatalogEntry(Builder builder) {
        this.capabilities = builder.capabilities.map(value -> List.copyOf(value));
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        this.platform = builder.platform;
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> capabilities() { return capabilities; }
    public String id() { return id; }
    public String name() { return name; }
    public MachineCatalogOrigin origin() { return origin; }
    public Field<MachineCatalogPlatform> platform() { return platform; }
    public MachineCatalogStatus status() { return status; }

    public static MachineCatalogEntry fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineCatalogEntry");
        Builder builder = builder();
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(Wire.array(rawCapabilities, "MachineCatalogEntry.capabilities", item -> Wire.string(item, "MachineCatalogEntry.capabilities item")));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "MachineCatalogEntry.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "MachineCatalogEntry.name"));
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(MachineCatalogOrigin.fromWire(rawOrigin));
        Object rawPlatform = Wire.optional(object, "platform");
        if (!Wire.isMissing(rawPlatform)) {
            builder.platform(rawPlatform == null ? null : MachineCatalogPlatform.fromWire(rawPlatform));
        }
        Object rawStatus = Wire.required(object, "status");
        builder.status(MachineCatalogStatus.fromWire(rawStatus));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "origin", origin);
        Wire.put(object, "platform", platform);
        Wire.put(object, "status", status);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineCatalogEntry that)) return false;
        return Objects.equals(capabilities, that.capabilities) && Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(origin, that.origin) && Objects.equals(platform, that.platform) && Objects.equals(status, that.status);
    }

    @Override
    public int hashCode() { return Objects.hash(capabilities, id, name, origin, platform, status); }

    @Override
    public String toString() { return "MachineCatalogEntry" + toWire(); }

    public static final class Builder {
        private Field<List<String>> capabilities = Field.omitted();
        private String id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private MachineCatalogOrigin origin;
        private boolean originSet;
        private Field<MachineCatalogPlatform> platform = Field.omitted();
        private MachineCatalogStatus status;
        private boolean statusSet;

        public Builder capabilities(List<String> value) {
            this.capabilities = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder origin(MachineCatalogOrigin value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder platform(MachineCatalogPlatform value) {
            this.platform = Field.ofNullable(value);
            return this;
        }
        public Builder status(MachineCatalogStatus value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public MachineCatalogEntry build() { return new MachineCatalogEntry(this); }
    }
}
