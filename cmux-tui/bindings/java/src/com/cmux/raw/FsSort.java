// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsSort implements WireValue {
    private final Field<FsSortDirection> dir;
    private final Field<Boolean> dirsFirst;
    private final Field<FsSortKey> key;

    private FsSort(Builder builder) {
        this.dir = builder.dir;
        this.dirsFirst = builder.dirsFirst;
        this.key = builder.key;
    }

    public static Builder builder() { return new Builder(); }

    public Field<FsSortDirection> dir() { return dir; }
    public Field<Boolean> dirsFirst() { return dirsFirst; }
    public Field<FsSortKey> key() { return key; }

    public static FsSort fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsSort");
        Builder builder = builder();
        Object rawDir = Wire.optional(object, "dir");
        if (!Wire.isMissing(rawDir)) {
            builder.dir(FsSortDirection.fromWire(rawDir));
        }
        Object rawDirsFirst = Wire.optional(object, "dirs_first");
        if (!Wire.isMissing(rawDirsFirst)) {
            builder.dirsFirst(Wire.bool(rawDirsFirst, "FsSort.dirs_first"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(FsSortKey.fromWire(rawKey));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dir", dir);
        Wire.put(object, "dirs_first", dirsFirst);
        Wire.put(object, "key", key);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsSort that)) return false;
        return Objects.equals(dir, that.dir) && Objects.equals(dirsFirst, that.dirsFirst) && Objects.equals(key, that.key);
    }

    @Override
    public int hashCode() { return Objects.hash(dir, dirsFirst, key); }

    @Override
    public String toString() { return "FsSort" + toWire(); }

    public static final class Builder {
        private Field<FsSortDirection> dir = Field.omitted();
        private Field<Boolean> dirsFirst = Field.omitted();
        private Field<FsSortKey> key = Field.omitted();

        public Builder dir(FsSortDirection value) {
            this.dir = Field.of(value);
            return this;
        }
        public Builder dirsFirst(Boolean value) {
            this.dirsFirst = Field.of(value);
            return this;
        }
        public Builder key(FsSortKey value) {
            this.key = Field.of(value);
            return this;
        }
        public FsSort build() { return new FsSort(this); }
    }
}
