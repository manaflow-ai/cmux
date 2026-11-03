// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LongJob implements WireValue {
    private final List<LongJobBlock> blocks;
    private final boolean cancellable;
    private final Field<String> detail;
    private final Field<UInt64> done;
    private final String id;
    private final String kind;
    private final UInt64 startedMs;
    private final String title;
    private final Field<UInt64> total;
    private final Field<String> unit;
    private final UInt64 updatedMs;

    private LongJob(Builder builder) {
        if (!builder.blocksSet) throw new IllegalArgumentException("blocks is required");
        this.blocks = List.copyOf(Wire.nonNull(builder.blocks, "blocks"));
        if (!builder.cancellableSet) throw new IllegalArgumentException("cancellable is required");
        this.cancellable = builder.cancellable;
        this.detail = builder.detail;
        this.done = builder.done;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.startedMsSet) throw new IllegalArgumentException("started_ms is required");
        this.startedMs = Wire.nonNull(builder.startedMs, "started_ms");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        this.total = builder.total;
        this.unit = builder.unit;
        if (!builder.updatedMsSet) throw new IllegalArgumentException("updated_ms is required");
        this.updatedMs = Wire.nonNull(builder.updatedMs, "updated_ms");
    }

    public static Builder builder() { return new Builder(); }

    public List<LongJobBlock> blocks() { return blocks; }
    public boolean cancellable() { return cancellable; }
    public Field<String> detail() { return detail; }
    public Field<UInt64> done() { return done; }
    public String id() { return id; }
    public String kind() { return kind; }
    public UInt64 startedMs() { return startedMs; }
    public String title() { return title; }
    public Field<UInt64> total() { return total; }
    public Field<String> unit() { return unit; }
    public UInt64 updatedMs() { return updatedMs; }

    public static LongJob fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LongJob");
        Builder builder = builder();
        Object rawBlocks = Wire.required(object, "blocks");
        builder.blocks(Wire.array(rawBlocks, "LongJob.blocks", item -> LongJobBlock.fromWire(item)));
        Object rawCancellable = Wire.required(object, "cancellable");
        builder.cancellable(Wire.bool(rawCancellable, "LongJob.cancellable"));
        Object rawDetail = Wire.optional(object, "detail");
        if (!Wire.isMissing(rawDetail)) {
            builder.detail(Wire.string(rawDetail, "LongJob.detail"));
        }
        Object rawDone = Wire.optional(object, "done");
        if (!Wire.isMissing(rawDone)) {
            builder.done(Wire.uint64(rawDone, "LongJob.done"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "LongJob.id"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "LongJob.kind"));
        Object rawStartedMs = Wire.required(object, "started_ms");
        builder.startedMs(Wire.uint64(rawStartedMs, "LongJob.started_ms"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "LongJob.title"));
        Object rawTotal = Wire.optional(object, "total");
        if (!Wire.isMissing(rawTotal)) {
            builder.total(Wire.uint64(rawTotal, "LongJob.total"));
        }
        Object rawUnit = Wire.optional(object, "unit");
        if (!Wire.isMissing(rawUnit)) {
            builder.unit(Wire.string(rawUnit, "LongJob.unit"));
        }
        Object rawUpdatedMs = Wire.required(object, "updated_ms");
        builder.updatedMs(Wire.uint64(rawUpdatedMs, "LongJob.updated_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "blocks", blocks);
        Wire.put(object, "cancellable", cancellable);
        Wire.put(object, "detail", detail);
        Wire.put(object, "done", done);
        Wire.put(object, "id", id);
        Wire.put(object, "kind", kind);
        Wire.put(object, "started_ms", startedMs);
        Wire.put(object, "title", title);
        Wire.put(object, "total", total);
        Wire.put(object, "unit", unit);
        Wire.put(object, "updated_ms", updatedMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LongJob that)) return false;
        return Objects.equals(blocks, that.blocks) && Objects.equals(cancellable, that.cancellable) && Objects.equals(detail, that.detail) && Objects.equals(done, that.done) && Objects.equals(id, that.id) && Objects.equals(kind, that.kind) && Objects.equals(startedMs, that.startedMs) && Objects.equals(title, that.title) && Objects.equals(total, that.total) && Objects.equals(unit, that.unit) && Objects.equals(updatedMs, that.updatedMs);
    }

    @Override
    public int hashCode() { return Objects.hash(blocks, cancellable, detail, done, id, kind, startedMs, title, total, unit, updatedMs); }

    @Override
    public String toString() { return "LongJob" + toWire(); }

    public static final class Builder {
        private List<LongJobBlock> blocks;
        private boolean blocksSet;
        private Boolean cancellable;
        private boolean cancellableSet;
        private Field<String> detail = Field.omitted();
        private Field<UInt64> done = Field.omitted();
        private String id;
        private boolean idSet;
        private String kind;
        private boolean kindSet;
        private UInt64 startedMs;
        private boolean startedMsSet;
        private String title;
        private boolean titleSet;
        private Field<UInt64> total = Field.omitted();
        private Field<String> unit = Field.omitted();
        private UInt64 updatedMs;
        private boolean updatedMsSet;

        public Builder blocks(List<LongJobBlock> value) {
            this.blocks = value;
            this.blocksSet = true;
            return this;
        }
        public Builder cancellable(boolean value) {
            this.cancellable = value;
            this.cancellableSet = true;
            return this;
        }
        public Builder detail(String value) {
            this.detail = Field.of(value);
            return this;
        }
        public Builder done(UInt64 value) {
            this.done = Field.of(value);
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder startedMs(UInt64 value) {
            this.startedMs = value;
            this.startedMsSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = Field.of(value);
            return this;
        }
        public Builder unit(String value) {
            this.unit = Field.of(value);
            return this;
        }
        public Builder updatedMs(UInt64 value) {
            this.updatedMs = value;
            this.updatedMsSet = true;
            return this;
        }
        public LongJob build() { return new LongJob(this); }
    }
}
