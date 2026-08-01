// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-browser-tab request. Protocol v5; authority: control. */
public final class NewBrowserTabRequest implements WireValue {
    private final Field<Boolean> activate;
    private final Field<Integer> cols;
    private final Field<UInt64> index;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;
    private final String url;

    private NewBrowserTabRequest(Builder builder) {
        this.activate = builder.activate;
        this.cols = builder.cols;
        this.index = builder.index;
        this.pane = builder.pane;
        this.rows = builder.rows;
        if (!builder.urlSet) throw new IllegalArgumentException("url is required");
        this.url = Wire.nonNull(builder.url, "url");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public Field<Integer> cols() { return cols; }
    public Field<UInt64> index() { return index; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public String url() { return url; }

    public static NewBrowserTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewBrowserTabRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "NewBrowserTabRequest.activate"));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewBrowserTabRequest.cols"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "NewBrowserTabRequest.index"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewBrowserTabRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewBrowserTabRequest.rows"));
        }
        Object rawUrl = Wire.required(object, "url");
        builder.url(Wire.string(rawUrl, "NewBrowserTabRequest.url"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "cols", cols);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewBrowserTabRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(cols, that.cols) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, cols, index, pane, rows, url); }

    @Override
    public String toString() { return "NewBrowserTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private String url;
        private boolean urlSet;

        public Builder activate(Boolean value) {
            this.activate = Field.ofNullable(value);
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = value;
            this.urlSet = true;
            return this;
        }
        public NewBrowserTabRequest build() { return new NewBrowserTabRequest(this); }
    }
}
