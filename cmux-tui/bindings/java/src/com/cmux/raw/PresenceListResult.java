// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PresenceListResult implements WireValue {
    private final List<PresenceEntry> entries;

    private PresenceListResult(Builder builder) {
        if (!builder.entriesSet) throw new IllegalArgumentException("entries is required");
        this.entries = List.copyOf(Wire.nonNull(builder.entries, "entries"));
    }

    public static Builder builder() { return new Builder(); }

    public List<PresenceEntry> entries() { return entries; }

    public static PresenceListResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceListResult");
        Builder builder = builder();
        Object rawEntries = Wire.required(object, "entries");
        builder.entries(Wire.array(rawEntries, "PresenceListResult.entries", item -> PresenceEntry.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "entries", entries);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceListResult that)) return false;
        return Objects.equals(entries, that.entries);
    }

    @Override
    public int hashCode() { return Objects.hash(entries); }

    @Override
    public String toString() { return "PresenceListResult" + toWire(); }

    public static final class Builder {
        private List<PresenceEntry> entries;
        private boolean entriesSet;

        public Builder entries(List<PresenceEntry> value) {
            this.entries = value;
            this.entriesSet = true;
            return this;
        }
        public PresenceListResult build() { return new PresenceListResult(this); }
    }
}
