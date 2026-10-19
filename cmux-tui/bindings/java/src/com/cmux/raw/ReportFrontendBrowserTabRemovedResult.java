// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReportFrontendBrowserTabRemovedResult implements WireValue {
    private final boolean removed;
    private final boolean replayed;

    private ReportFrontendBrowserTabRemovedResult(Builder builder) {
        if (!builder.removedSet) throw new IllegalArgumentException("removed is required");
        this.removed = builder.removed;
        if (!builder.replayedSet) throw new IllegalArgumentException("replayed is required");
        this.replayed = builder.replayed;
    }

    public static Builder builder() { return new Builder(); }

    public boolean removed() { return removed; }
    public boolean replayed() { return replayed; }

    public static ReportFrontendBrowserTabRemovedResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportFrontendBrowserTabRemovedResult");
        Builder builder = builder();
        Object rawRemoved = Wire.required(object, "removed");
        builder.removed(Wire.bool(rawRemoved, "ReportFrontendBrowserTabRemovedResult.removed"));
        Object rawReplayed = Wire.required(object, "replayed");
        builder.replayed(Wire.bool(rawReplayed, "ReportFrontendBrowserTabRemovedResult.replayed"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "removed", removed);
        Wire.put(object, "replayed", replayed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportFrontendBrowserTabRemovedResult that)) return false;
        return Objects.equals(removed, that.removed) && Objects.equals(replayed, that.replayed);
    }

    @Override
    public int hashCode() { return Objects.hash(removed, replayed); }

    @Override
    public String toString() { return "ReportFrontendBrowserTabRemovedResult" + toWire(); }

    public static final class Builder {
        private Boolean removed;
        private boolean removedSet;
        private Boolean replayed;
        private boolean replayedSet;

        public Builder removed(boolean value) {
            this.removed = value;
            this.removedSet = true;
            return this;
        }
        public Builder replayed(boolean value) {
            this.replayed = value;
            this.replayedSet = true;
            return this;
        }
        public ReportFrontendBrowserTabRemovedResult build() { return new ReportFrontendBrowserTabRemovedResult(this); }
    }
}
