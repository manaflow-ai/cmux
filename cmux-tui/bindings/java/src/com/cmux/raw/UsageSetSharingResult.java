// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class UsageSetSharingResult implements WireValue {
    private final String dir;
    private final boolean on;

    private UsageSetSharingResult(Builder builder) {
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        if (!builder.onSet) throw new IllegalArgumentException("on is required");
        this.on = builder.on;
    }

    public static Builder builder() { return new Builder(); }

    public String dir() { return dir; }
    public boolean on() { return on; }

    public static UsageSetSharingResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UsageSetSharingResult");
        Builder builder = builder();
        Object rawDir = Wire.required(object, "dir");
        builder.dir(Wire.string(rawDir, "UsageSetSharingResult.dir"));
        Object rawOn = Wire.required(object, "on");
        builder.on(Wire.bool(rawOn, "UsageSetSharingResult.on"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "on", on);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UsageSetSharingResult that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(on, that.on);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, on); }

    @Override
    public String toString() { return "UsageSetSharingResult" + toWire(); }

    public static final class Builder {
        private String dir;
        private boolean dirSet;
        private Boolean on;
        private boolean onSet;

        public Builder dir(String value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder on(boolean value) {
            this.on = value;
            this.onSet = true;
            return this;
        }
        public UsageSetSharingResult build() { return new UsageSetSharingResult(this); }
    }
}
