// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-app-tab request. Protocol v12; authority: control. */
public final class NewAppTabRequest implements WireValue {
    private final String app;
    private final Field<Integer> cols;
    private final Field<String> idempotencyKey;
    private final Field<UInt64> pane;
    private final Field<String> route;
    private final Field<Integer> rows;
    private final Field<UInt64> workspace;

    private NewAppTabRequest(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.cols = builder.cols;
        this.idempotencyKey = builder.idempotencyKey;
        this.pane = builder.pane;
        this.route = builder.route;
        this.rows = builder.rows;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<Integer> cols() { return cols; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public Field<UInt64> pane() { return pane; }
    public Field<String> route() { return route; }
    public Field<Integer> rows() { return rows; }
    public Field<UInt64> workspace() { return workspace; }

    public static NewAppTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewAppTabRequest");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "NewAppTabRequest.app"));
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewAppTabRequest.cols"));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "NewAppTabRequest.idempotency_key"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewAppTabRequest.pane"));
        }
        Object rawRoute = Wire.optional(object, "route");
        if (!Wire.isMissing(rawRoute)) {
            builder.route(rawRoute == null ? null : Wire.string(rawRoute, "NewAppTabRequest.route"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewAppTabRequest.rows"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "NewAppTabRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "cols", cols);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "pane", pane);
        Wire.put(object, "route", route);
        Wire.put(object, "rows", rows);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewAppTabRequest that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(cols, that.cols) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(pane, that.pane) && Objects.equals(route, that.route) && Objects.equals(rows, that.rows) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(app, cols, idempotencyKey, pane, route, rows, workspace); }

    @Override
    public String toString() { return "NewAppTabRequest" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<Integer> cols = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<String> route = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder route(String value) {
            this.route = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public NewAppTabRequest build() { return new NewAppTabRequest(this); }
    }
}
