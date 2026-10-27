// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class BrowserRuntimeStatusResult implements WireValue {
    private final String installed;
    private final String platform;
    private final List<BrowserRuntimeRow> runtimes;

    private BrowserRuntimeStatusResult(Builder builder) {
        if (!builder.installedSet) throw new IllegalArgumentException("installed is required");
        this.installed = builder.installed;
        if (!builder.platformSet) throw new IllegalArgumentException("platform is required");
        this.platform = Wire.nonNull(builder.platform, "platform");
        if (!builder.runtimesSet) throw new IllegalArgumentException("runtimes is required");
        this.runtimes = List.copyOf(Wire.nonNull(builder.runtimes, "runtimes"));
    }

    public static Builder builder() { return new Builder(); }

    public String installed() { return installed; }
    public String platform() { return platform; }
    public List<BrowserRuntimeRow> runtimes() { return runtimes; }

    public static BrowserRuntimeStatusResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BrowserRuntimeStatusResult");
        Builder builder = builder();
        Object rawInstalled = Wire.required(object, "installed");
        builder.installed(rawInstalled == null ? null : Wire.string(rawInstalled, "BrowserRuntimeStatusResult.installed"));
        Object rawPlatform = Wire.required(object, "platform");
        builder.platform(Wire.string(rawPlatform, "BrowserRuntimeStatusResult.platform"));
        Object rawRuntimes = Wire.required(object, "runtimes");
        builder.runtimes(Wire.array(rawRuntimes, "BrowserRuntimeStatusResult.runtimes", item -> BrowserRuntimeRow.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "installed", installed);
        Wire.put(object, "platform", platform);
        Wire.put(object, "runtimes", runtimes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BrowserRuntimeStatusResult that)) return false;
        return Objects.equals(installed, that.installed) && Objects.equals(platform, that.platform) && Objects.equals(runtimes, that.runtimes);
    }

    @Override
    public int hashCode() { return Objects.hash(installed, platform, runtimes); }

    @Override
    public String toString() { return "BrowserRuntimeStatusResult" + toWire(); }

    public static final class Builder {
        private String installed;
        private boolean installedSet;
        private String platform;
        private boolean platformSet;
        private List<BrowserRuntimeRow> runtimes;
        private boolean runtimesSet;

        public Builder installed(String value) {
            this.installed = value;
            this.installedSet = true;
            return this;
        }
        public Builder platform(String value) {
            this.platform = value;
            this.platformSet = true;
            return this;
        }
        public Builder runtimes(List<BrowserRuntimeRow> value) {
            this.runtimes = value;
            this.runtimesSet = true;
            return this;
        }
        public BrowserRuntimeStatusResult build() { return new BrowserRuntimeStatusResult(this); }
    }
}
