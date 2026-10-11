// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-screen request. Protocol v5; authority: control. */
public final class NewScreenRequest implements WireValue {
    private final Field<String> color;
    private final Field<Integer> cols;
    private final Field<String> cwd;
    private final Field<Map<String, String>> env;
    private final Field<String> group;
    private final Field<String> icon;
    private final Field<UInt64> index;
    private final Field<Boolean> pinned;
    private final Field<Integer> rows;
    private final Field<String> screenName;
    private final Field<List<String>> shellArgs;
    private final Field<String> terminalId;
    private final Field<UInt64> workspace;

    private NewScreenRequest(Builder builder) {
        this.color = builder.color;
        this.cols = builder.cols;
        this.cwd = builder.cwd;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        this.group = builder.group;
        this.icon = builder.icon;
        this.index = builder.index;
        this.pinned = builder.pinned;
        this.rows = builder.rows;
        this.screenName = builder.screenName;
        this.shellArgs = builder.shellArgs.map(value -> List.copyOf(value));
        this.terminalId = builder.terminalId;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> color() { return color; }
    public Field<Integer> cols() { return cols; }
    public Field<String> cwd() { return cwd; }
    public Field<Map<String, String>> env() { return env; }
    public Field<String> group() { return group; }
    public Field<String> icon() { return icon; }
    public Field<UInt64> index() { return index; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<Integer> rows() { return rows; }
    public Field<String> screenName() { return screenName; }
    public Field<List<String>> shellArgs() { return shellArgs; }
    public Field<String> terminalId() { return terminalId; }
    public Field<UInt64> workspace() { return workspace; }

    public static NewScreenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewScreenRequest");
        Builder builder = builder();
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "NewScreenRequest.color"));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewScreenRequest.cols"));
        }
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "NewScreenRequest.cwd"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "NewScreenRequest.env", item -> Wire.string(item, "NewScreenRequest.env value")));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "NewScreenRequest.group"));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "NewScreenRequest.icon"));
        }
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "NewScreenRequest.index"));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(rawPinned == null ? null : Wire.bool(rawPinned, "NewScreenRequest.pinned"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewScreenRequest.rows"));
        }
        Object rawScreenName = Wire.optional(object, "screen_name");
        if (!Wire.isMissing(rawScreenName)) {
            builder.screenName(rawScreenName == null ? null : Wire.string(rawScreenName, "NewScreenRequest.screen_name"));
        }
        Object rawShellArgs = Wire.optional(object, "shell_args");
        if (!Wire.isMissing(rawShellArgs)) {
            builder.shellArgs(rawShellArgs == null ? null : Wire.array(rawShellArgs, "NewScreenRequest.shell_args", item -> Wire.string(item, "NewScreenRequest.shell_args item")));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "NewScreenRequest.terminal_id"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "NewScreenRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "color", color);
        Wire.put(object, "cols", cols);
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "env", env);
        Wire.put(object, "group", group);
        Wire.put(object, "icon", icon);
        Wire.put(object, "index", index);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "rows", rows);
        Wire.put(object, "screen_name", screenName);
        Wire.put(object, "shell_args", shellArgs);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewScreenRequest that)) return false;
        return Objects.equals(color, that.color) && Objects.equals(cols, that.cols) && Objects.equals(cwd, that.cwd) && Objects.equals(env, that.env) && Objects.equals(group, that.group) && Objects.equals(icon, that.icon) && Objects.equals(index, that.index) && Objects.equals(pinned, that.pinned) && Objects.equals(rows, that.rows) && Objects.equals(screenName, that.screenName) && Objects.equals(shellArgs, that.shellArgs) && Objects.equals(terminalId, that.terminalId) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(color, cols, cwd, env, group, icon, index, pinned, rows, screenName, shellArgs, terminalId, workspace); }

    @Override
    public String toString() { return "NewScreenRequest" + toWire(); }

    public static final class Builder {
        private Field<String> color = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<String> cwd = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<String> icon = Field.omitted();
        private Field<UInt64> index = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> screenName = Field.omitted();
        private Field<List<String>> shellArgs = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder color(String value) {
            this.color = Field.ofNullable(value);
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
        public Builder env(Map<String, String> value) {
            this.env = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder screenName(String value) {
            this.screenName = Field.ofNullable(value);
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
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public NewScreenRequest build() { return new NewScreenRequest(this); }
    }
}
