// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable split request. Protocol v5; authority: control. */
public final class SplitRequest implements WireValue {
    private final Field<Boolean> activate;
    private final Field<Integer> cols;
    private final SplitDirection dir;
    private final Field<PaneKind> kind;
    private final UInt64 pane;
    private final Field<Integer> rows;
    private final Field<String> url;

    private SplitRequest(Builder builder) {
        this.activate = builder.activate;
        this.cols = builder.cols;
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        this.kind = builder.kind;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public Field<Integer> cols() { return cols; }
    public SplitDirection dir() { return dir; }
    public Field<PaneKind> kind() { return kind; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<String> url() { return url; }

    public static SplitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SplitRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "SplitRequest.activate"));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "SplitRequest.cols"));
        }
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : PaneKind.fromWire(rawKind));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "SplitRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "SplitRequest.rows"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "SplitRequest.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "cols", cols);
        Wire.put(object, "dir", dir);
        Wire.put(object, "kind", kind);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SplitRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(cols, that.cols) && Objects.equals(dir, that.dir) && Objects.equals(kind, that.kind) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, cols, dir, kind, pane, rows, url); }

    @Override
    public String toString() { return "SplitRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private SplitDirection dir;
        private boolean dirSet;
        private Field<PaneKind> kind = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();
        private Field<String> url = Field.omitted();

        public Builder activate(Boolean value) {
            this.activate = Field.ofNullable(value);
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder dir(SplitDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder kind(PaneKind value) {
            this.kind = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public SplitRequest build() { return new SplitRequest(this); }
    }
}
