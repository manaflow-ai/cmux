// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsListResult implements WireValue {
    private final List<AppRecord> apps;
    private final UInt64 revision;

    private AppsListResult(Builder builder) {
        if (!builder.appsSet) throw new IllegalArgumentException("apps is required");
        this.apps = List.copyOf(Wire.nonNull(builder.apps, "apps"));
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public List<AppRecord> apps() { return apps; }
    public UInt64 revision() { return revision; }

    public static AppsListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsListResult");
        Builder builder = builder();
        Object rawApps = Wire.required(object, "apps");
        builder.apps(Wire.array(rawApps, "AppsListResult.apps", item -> AppRecord.fromWire(item)));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "AppsListResult.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "apps", apps);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsListResult that)) return false;
        return Objects.equals(apps, that.apps) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(apps, revision); }

    @Override
    public String toString() { return "AppsListResult" + toWire(); }

    public static final class Builder {
        private List<AppRecord> apps;
        private boolean appsSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder apps(List<AppRecord> value) {
            this.apps = value;
            this.appsSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public AppsListResult build() { return new AppsListResult(this); }
    }
}
