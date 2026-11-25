// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HomeInboxResult implements WireValue {
    private final String cloud;
    private final Field<Boolean> full;
    private final String me;
    private final Field<UInt64> offset;
    private final Field<String> order;
    private final Field<List<String>> removed;
    private final Field<UInt64> revision;
    private final List<HomeInboxRow> rows;
    private final Field<UInt64> total;
    private final Field<Boolean> window;

    private HomeInboxResult(Builder builder) {
        if (!builder.cloudSet) throw new IllegalArgumentException("cloud is required");
        this.cloud = Wire.nonNull(builder.cloud, "cloud");
        this.full = builder.full;
        if (!builder.meSet) throw new IllegalArgumentException("me is required");
        this.me = Wire.nonNull(builder.me, "me");
        this.offset = builder.offset;
        this.order = builder.order;
        this.removed = builder.removed.map(value -> List.copyOf(value));
        this.revision = builder.revision;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
        this.total = builder.total;
        this.window = builder.window;
    }

    public static Builder builder() { return new Builder(); }

    public String cloud() { return cloud; }
    public Field<Boolean> full() { return full; }
    public String me() { return me; }
    public Field<UInt64> offset() { return offset; }
    public Field<String> order() { return order; }
    public Field<List<String>> removed() { return removed; }
    public Field<UInt64> revision() { return revision; }
    public List<HomeInboxRow> rows() { return rows; }
    public Field<UInt64> total() { return total; }
    public Field<Boolean> window() { return window; }

    public static HomeInboxResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeInboxResult");
        Builder builder = builder();
        Object rawCloud = Wire.required(object, "cloud");
        builder.cloud(Wire.string(rawCloud, "HomeInboxResult.cloud"));
        Object rawFull = Wire.optional(object, "full");
        if (!Wire.isMissing(rawFull)) {
            builder.full(Wire.bool(rawFull, "HomeInboxResult.full"));
        }
        Object rawMe = Wire.required(object, "me");
        builder.me(Wire.string(rawMe, "HomeInboxResult.me"));
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(Wire.uint64(rawOffset, "HomeInboxResult.offset"));
        }
        Object rawOrder = Wire.optional(object, "order");
        if (!Wire.isMissing(rawOrder)) {
            builder.order(Wire.string(rawOrder, "HomeInboxResult.order"));
        }
        Object rawRemoved = Wire.optional(object, "removed");
        if (!Wire.isMissing(rawRemoved)) {
            builder.removed(Wire.array(rawRemoved, "HomeInboxResult.removed", item -> Wire.string(item, "HomeInboxResult.removed item")));
        }
        Object rawRevision = Wire.optional(object, "revision");
        if (!Wire.isMissing(rawRevision)) {
            builder.revision(Wire.uint64(rawRevision, "HomeInboxResult.revision"));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "HomeInboxResult.rows", item -> HomeInboxRow.fromWire(item)));
        Object rawTotal = Wire.optional(object, "total");
        if (!Wire.isMissing(rawTotal)) {
            builder.total(Wire.uint64(rawTotal, "HomeInboxResult.total"));
        }
        Object rawWindow = Wire.optional(object, "window");
        if (!Wire.isMissing(rawWindow)) {
            builder.window(Wire.bool(rawWindow, "HomeInboxResult.window"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cloud", cloud);
        Wire.put(object, "full", full);
        Wire.put(object, "me", me);
        Wire.put(object, "offset", offset);
        Wire.put(object, "order", order);
        Wire.put(object, "removed", removed);
        Wire.put(object, "revision", revision);
        Wire.put(object, "rows", rows);
        Wire.put(object, "total", total);
        Wire.put(object, "window", window);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeInboxResult that)) return false;
        return Objects.equals(cloud, that.cloud) && Objects.equals(full, that.full) && Objects.equals(me, that.me) && Objects.equals(offset, that.offset) && Objects.equals(order, that.order) && Objects.equals(removed, that.removed) && Objects.equals(revision, that.revision) && Objects.equals(rows, that.rows) && Objects.equals(total, that.total) && Objects.equals(window, that.window);
    }

    @Override
    public int hashCode() { return Objects.hash(cloud, full, me, offset, order, removed, revision, rows, total, window); }

    @Override
    public String toString() { return "HomeInboxResult" + toWire(); }

    public static final class Builder {
        private String cloud;
        private boolean cloudSet;
        private Field<Boolean> full = Field.omitted();
        private String me;
        private boolean meSet;
        private Field<UInt64> offset = Field.omitted();
        private Field<String> order = Field.omitted();
        private Field<List<String>> removed = Field.omitted();
        private Field<UInt64> revision = Field.omitted();
        private List<HomeInboxRow> rows;
        private boolean rowsSet;
        private Field<UInt64> total = Field.omitted();
        private Field<Boolean> window = Field.omitted();

        public Builder cloud(String value) {
            this.cloud = value;
            this.cloudSet = true;
            return this;
        }
        public Builder full(Boolean value) {
            this.full = Field.of(value);
            return this;
        }
        public Builder me(String value) {
            this.me = value;
            this.meSet = true;
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.of(value);
            return this;
        }
        public Builder order(String value) {
            this.order = Field.of(value);
            return this;
        }
        public Builder removed(List<String> value) {
            this.removed = Field.of(value);
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = Field.of(value);
            return this;
        }
        public Builder rows(List<HomeInboxRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = Field.of(value);
            return this;
        }
        public Builder window(Boolean value) {
            this.window = Field.of(value);
            return this;
        }
        public HomeInboxResult build() { return new HomeInboxResult(this); }
    }
}
