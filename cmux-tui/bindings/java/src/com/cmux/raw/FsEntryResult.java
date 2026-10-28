// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsEntryResult implements WireValue {
    private final FsEntry entry;

    private FsEntryResult(Builder builder) {
        if (!builder.entrySet) throw new IllegalArgumentException("entry is required");
        this.entry = Wire.nonNull(builder.entry, "entry");
    }

    public static Builder builder() { return new Builder(); }

    public FsEntry entry() { return entry; }

    public static FsEntryResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsEntryResult");
        Builder builder = builder();
        Object rawEntry = Wire.required(object, "entry");
        builder.entry(FsEntry.fromWire(rawEntry));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "entry", entry);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsEntryResult that)) return false;
        return Objects.equals(entry, that.entry);
    }

    @Override
    public int hashCode() { return Objects.hash(entry); }

    @Override
    public String toString() { return "FsEntryResult" + toWire(); }

    public static final class Builder {
        private FsEntry entry;
        private boolean entrySet;

        public Builder entry(FsEntry value) {
            this.entry = value;
            this.entrySet = true;
            return this;
        }
        public FsEntryResult build() { return new FsEntryResult(this); }
    }
}
