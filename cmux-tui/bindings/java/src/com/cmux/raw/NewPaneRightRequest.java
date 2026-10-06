// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-pane-right request. Protocol v9; authority: control. */
public final class NewPaneRightRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final Field<Boolean> keep;
    private final Field<PaneKind> kind;
    private final UInt64 pane;
    private final Field<Integer> rows;
    private final Field<List<String>> shellArgs;
    private final Field<String> terminalId;
    private final Field<String> url;
    private final Field<Double> width;

    private NewPaneRightRequest(Builder builder) {
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.keep = builder.keep;
        this.kind = builder.kind;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.rows = builder.rows;
        this.shellArgs = builder.shellArgs.map(value -> List.copyOf(value));
        this.terminalId = builder.terminalId;
        this.url = builder.url;
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public Field<Boolean> keep() { return keep; }
    public Field<PaneKind> kind() { return kind; }
    public UInt64 pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<List<String>> shellArgs() { return shellArgs; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> url() { return url; }
    public Field<Double> width() { return width; }

    public static NewPaneRightRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewPaneRightRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewPaneRightRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "NewPaneRightRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "NewPaneRightRequest.env", item -> Wire.string(item, "NewPaneRightRequest.env value")));
        }
        Object rawKeep = Wire.optional(object, "keep");
        if (!Wire.isMissing(rawKeep)) {
            builder.keep(Wire.bool(rawKeep, "NewPaneRightRequest.keep"));
        }
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : PaneKind.fromWire(rawKind));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewPaneRightRequest.pane"));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewPaneRightRequest.rows"));
        }
        Object rawShellArgs = Wire.optional(object, "shell_args");
        if (!Wire.isMissing(rawShellArgs)) {
            builder.shellArgs(rawShellArgs == null ? null : Wire.array(rawShellArgs, "NewPaneRightRequest.shell_args", item -> Wire.string(item, "NewPaneRightRequest.shell_args item")));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "NewPaneRightRequest.terminal_id"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "NewPaneRightRequest.url"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.float64(rawWidth, "NewPaneRightRequest.width"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "keep", keep);
        Wire.put(object, "kind", kind);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "shell_args", shellArgs);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "url", url);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewPaneRightRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(keep, that.keep) && Objects.equals(kind, that.kind) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(shellArgs, that.shellArgs) && Objects.equals(terminalId, that.terminalId) && Objects.equals(url, that.url) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, cwd, env, keep, kind, pane, rows, shellArgs, terminalId, url, width); }

    @Override
    public String toString() { return "NewPaneRightRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private Field<Boolean> keep = Field.omitted();
        private Field<PaneKind> kind = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<Integer> rows = Field.omitted();
        private Field<List<String>> shellArgs = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> url = Field.omitted();
        private Field<Double> width = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder env(Map<String, String> value) {
            this.env = Field.ofNullable(value);
            return this;
        }
        public Builder keep(Boolean value) {
            this.keep = Field.of(value);
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
        public Builder shellArgs(List<String> value) {
            this.shellArgs = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
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
        public NewPaneRightRequest build() { return new NewPaneRightRequest(this); }
    }
}
