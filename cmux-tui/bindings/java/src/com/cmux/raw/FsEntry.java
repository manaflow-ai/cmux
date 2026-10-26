// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsEntry implements WireValue {
    private final Field<Boolean> hidden;
    private final FsEntryKind kind;
    private final UInt64 mtime;
    private final String name;
    private final Field<String> revision;
    private final UInt64 size;
    private final Field<FsEntryKind> targetKind;

    private FsEntry(Builder builder) {
        this.hidden = builder.hidden;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.mtimeSet) throw new IllegalArgumentException("mtime is required");
        this.mtime = builder.mtime;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        this.revision = builder.revision;
        if (!builder.sizeSet) throw new IllegalArgumentException("size is required");
        this.size = builder.size;
        this.targetKind = builder.targetKind;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> hidden() { return hidden; }
    public FsEntryKind kind() { return kind; }
    public UInt64 mtime() { return mtime; }
    public String name() { return name; }
    public Field<String> revision() { return revision; }
    public UInt64 size() { return size; }
    public Field<FsEntryKind> targetKind() { return targetKind; }

    public static FsEntry fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsEntry");
        Builder builder = builder();
        Object rawHidden = Wire.optional(object, "hidden");
        if (!Wire.isMissing(rawHidden)) {
            builder.hidden(Wire.bool(rawHidden, "FsEntry.hidden"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(FsEntryKind.fromWire(rawKind));
        Object rawMtime = Wire.required(object, "mtime");
        builder.mtime(rawMtime == null ? null : Wire.uint64(rawMtime, "FsEntry.mtime"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "FsEntry.name"));
        Object rawRevision = Wire.optional(object, "revision");
        if (!Wire.isMissing(rawRevision)) {
            builder.revision(Wire.string(rawRevision, "FsEntry.revision"));
        }
        Object rawSize = Wire.required(object, "size");
        builder.size(rawSize == null ? null : Wire.uint64(rawSize, "FsEntry.size"));
        Object rawTargetKind = Wire.optional(object, "target_kind");
        if (!Wire.isMissing(rawTargetKind)) {
            builder.targetKind(FsEntryKind.fromWire(rawTargetKind));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hidden", hidden);
        Wire.put(object, "kind", kind);
        Wire.put(object, "mtime", mtime);
        Wire.put(object, "name", name);
        Wire.put(object, "revision", revision);
        Wire.put(object, "size", size);
        Wire.put(object, "target_kind", targetKind);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsEntry that)) return false;
        return Objects.equals(hidden, that.hidden) && Objects.equals(kind, that.kind) && Objects.equals(mtime, that.mtime) && Objects.equals(name, that.name) && Objects.equals(revision, that.revision) && Objects.equals(size, that.size) && Objects.equals(targetKind, that.targetKind);
    }

    @Override
    public int hashCode() { return Objects.hash(hidden, kind, mtime, name, revision, size, targetKind); }

    @Override
    public String toString() { return "FsEntry" + toWire(); }

    public static final class Builder {
        private Field<Boolean> hidden = Field.omitted();
        private FsEntryKind kind;
        private boolean kindSet;
        private UInt64 mtime;
        private boolean mtimeSet;
        private String name;
        private boolean nameSet;
        private Field<String> revision = Field.omitted();
        private UInt64 size;
        private boolean sizeSet;
        private Field<FsEntryKind> targetKind = Field.omitted();

        public Builder hidden(Boolean value) {
            this.hidden = Field.of(value);
            return this;
        }
        public Builder kind(FsEntryKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder mtime(UInt64 value) {
            this.mtime = value;
            this.mtimeSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder revision(String value) {
            this.revision = Field.of(value);
            return this;
        }
        public Builder size(UInt64 value) {
            this.size = value;
            this.sizeSet = true;
            return this;
        }
        public Builder targetKind(FsEntryKind value) {
            this.targetKind = Field.of(value);
            return this;
        }
        public FsEntry build() { return new FsEntry(this); }
    }
}
