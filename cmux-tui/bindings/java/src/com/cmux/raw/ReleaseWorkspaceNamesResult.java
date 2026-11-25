// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReleaseWorkspaceNamesResult implements WireValue {
    /** Workspace names this call handed back to the automatic namer. */
    private final UInt64 released;
    /** User-owned names left pinned: a row renamed between the read and its release. */
    private final UInt64 stillPinned;

    private ReleaseWorkspaceNamesResult(Builder builder) {
        if (!builder.releasedSet) throw new IllegalArgumentException("released is required");
        this.released = Wire.nonNull(builder.released, "released");
        if (!builder.stillPinnedSet) throw new IllegalArgumentException("still_pinned is required");
        this.stillPinned = Wire.nonNull(builder.stillPinned, "still_pinned");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 released() { return released; }
    public UInt64 stillPinned() { return stillPinned; }

    public static ReleaseWorkspaceNamesResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReleaseWorkspaceNamesResult");
        Builder builder = builder();
        Object rawReleased = Wire.required(object, "released");
        builder.released(Wire.uint64(rawReleased, "ReleaseWorkspaceNamesResult.released"));
        Object rawStillPinned = Wire.required(object, "still_pinned");
        builder.stillPinned(Wire.uint64(rawStillPinned, "ReleaseWorkspaceNamesResult.still_pinned"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "released", released);
        Wire.put(object, "still_pinned", stillPinned);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReleaseWorkspaceNamesResult that)) return false;
        return Objects.equals(released, that.released) && Objects.equals(stillPinned, that.stillPinned);
    }

    @Override
    public int hashCode() { return Objects.hash(released, stillPinned); }

    @Override
    public String toString() { return "ReleaseWorkspaceNamesResult" + toWire(); }

    public static final class Builder {
        private UInt64 released;
        private boolean releasedSet;
        private UInt64 stillPinned;
        private boolean stillPinnedSet;

        public Builder released(UInt64 value) {
            this.released = value;
            this.releasedSet = true;
            return this;
        }
        public Builder stillPinned(UInt64 value) {
            this.stillPinned = value;
            this.stillPinnedSet = true;
            return this;
        }
        public ReleaseWorkspaceNamesResult build() { return new ReleaseWorkspaceNamesResult(this); }
    }
}
