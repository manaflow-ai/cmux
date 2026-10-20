// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable create-surface-with-receipt request. Protocol v10; authority: control. */
public final class CreateSurfaceWithReceiptRequest implements WireValue {
    private final Field<List<String>> argv;
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<String> idempotencyKey;
    private final String operation;
    private final String origin;
    private final Field<UInt64> pane;
    private final String receipt;
    private final Field<Integer> rows;
    private final Field<List<ResourceSelectors>> selectorFallbacks;
    private final Field<ResourceSelectors> selectors;
    private final Field<String> url;
    private final Field<Double> width;
    private final Field<UInt64> workspace;

    private CreateSurfaceWithReceiptRequest(Builder builder) {
        this.argv = builder.argv.map(value -> List.copyOf(value));
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.idempotencyKey = builder.idempotencyKey;
        if (!builder.operationSet) throw new IllegalArgumentException("operation is required");
        this.operation = Wire.nonNull(builder.operation, "operation");
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        this.pane = builder.pane;
        if (!builder.receiptSet) throw new IllegalArgumentException("receipt is required");
        this.receipt = Wire.nonNull(builder.receipt, "receipt");
        this.rows = builder.rows;
        this.selectorFallbacks = builder.selectorFallbacks.map(value -> List.copyOf(value));
        this.selectors = builder.selectors;
        this.url = builder.url;
        this.width = builder.width;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> argv() { return argv; }
    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<String> idempotencyKey() { return idempotencyKey; }
    public String operation() { return operation; }
    public String origin() { return origin; }
    public Field<UInt64> pane() { return pane; }
    public String receipt() { return receipt; }
    public Field<Integer> rows() { return rows; }
    public Field<List<ResourceSelectors>> selectorFallbacks() { return selectorFallbacks; }
    public Field<ResourceSelectors> selectors() { return selectors; }
    public Field<String> url() { return url; }
    public Field<Double> width() { return width; }
    public Field<UInt64> workspace() { return workspace; }

    public static CreateSurfaceWithReceiptRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CreateSurfaceWithReceiptRequest");
        Builder builder = builder();
        Object rawArgv = Wire.optional(object, "argv");
        if (!Wire.isMissing(rawArgv)) {
            builder.argv(rawArgv == null ? null : Wire.array(rawArgv, "CreateSurfaceWithReceiptRequest.argv", item -> Wire.string(item, "CreateSurfaceWithReceiptRequest.argv item")));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "CreateSurfaceWithReceiptRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "CreateSurfaceWithReceiptRequest.cwd"));
        }
        Object rawIdempotencyKey = Wire.optional(object, "idempotency_key");
        if (!Wire.isMissing(rawIdempotencyKey)) {
            builder.idempotencyKey(rawIdempotencyKey == null ? null : Wire.string(rawIdempotencyKey, "CreateSurfaceWithReceiptRequest.idempotency_key"));
        }
        Object rawOperation = Wire.required(object, "operation");
        builder.operation(Wire.string(rawOperation, "CreateSurfaceWithReceiptRequest.operation"));
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(Wire.string(rawOrigin, "CreateSurfaceWithReceiptRequest.origin"));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "CreateSurfaceWithReceiptRequest.pane"));
        }
        Object rawReceipt = Wire.required(object, "receipt");
        builder.receipt(Wire.string(rawReceipt, "CreateSurfaceWithReceiptRequest.receipt"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "CreateSurfaceWithReceiptRequest.rows"));
        }
        Object rawSelectorFallbacks = Wire.optional(object, "selector_fallbacks");
        if (!Wire.isMissing(rawSelectorFallbacks)) {
            builder.selectorFallbacks(Wire.array(rawSelectorFallbacks, "CreateSurfaceWithReceiptRequest.selector_fallbacks", item -> ResourceSelectors.fromWire(item)));
        }
        Object rawSelectors = Wire.optional(object, "selectors");
        if (!Wire.isMissing(rawSelectors)) {
            builder.selectors(rawSelectors == null ? null : ResourceSelectors.fromWire(rawSelectors));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "CreateSurfaceWithReceiptRequest.url"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.float64(rawWidth, "CreateSurfaceWithReceiptRequest.width"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "CreateSurfaceWithReceiptRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "argv", argv);
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "operation", operation);
        Wire.put(object, "origin", origin);
        Wire.put(object, "pane", pane);
        Wire.put(object, "receipt", receipt);
        Wire.put(object, "rows", rows);
        Wire.put(object, "selector_fallbacks", selectorFallbacks);
        Wire.put(object, "selectors", selectors);
        Wire.put(object, "url", url);
        Wire.put(object, "width", width);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CreateSurfaceWithReceiptRequest that)) return false;
        return Objects.equals(argv, that.argv) && Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(operation, that.operation) && Objects.equals(origin, that.origin) && Objects.equals(pane, that.pane) && Objects.equals(receipt, that.receipt) && Objects.equals(rows, that.rows) && Objects.equals(selectorFallbacks, that.selectorFallbacks) && Objects.equals(selectors, that.selectors) && Objects.equals(url, that.url) && Objects.equals(width, that.width) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(argv, cols, cwd, idempotencyKey, operation, origin, pane, receipt, rows, selectorFallbacks, selectors, url, width, workspace); }

    @Override
    public String toString() { return "CreateSurfaceWithReceiptRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> argv = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<String> idempotencyKey = Field.omitted();
        private String operation;
        private boolean operationSet;
        private String origin;
        private boolean originSet;
        private Field<UInt64> pane = Field.omitted();
        private String receipt;
        private boolean receiptSet;
        private Field<Integer> rows = Field.omitted();
        private Field<List<ResourceSelectors>> selectorFallbacks = Field.omitted();
        private Field<ResourceSelectors> selectors = Field.omitted();
        private Field<String> url = Field.omitted();
        private Field<Double> width = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder argv(List<String> value) {
            this.argv = Field.ofNullable(value);
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = Field.ofNullable(value);
            return this;
        }
        public Builder operation(String value) {
            this.operation = value;
            this.operationSet = true;
            return this;
        }
        public Builder origin(String value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder receipt(String value) {
            this.receipt = value;
            this.receiptSet = true;
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder selectorFallbacks(List<ResourceSelectors> value) {
            this.selectorFallbacks = Field.of(value);
            return this;
        }
        public Builder selectors(ResourceSelectors value) {
            this.selectors = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = Field.ofNullable(value);
            return this;
        }
        public Builder width(Double value) {
            this.width = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public CreateSurfaceWithReceiptRequest build() { return new CreateSurfaceWithReceiptRequest(this); }
    }
}
