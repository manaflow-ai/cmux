// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SplitRespawn implements WireValue {
    private final Field<String> cwd;
    private final Field<String> engine;
    private final Field<Map<String, String>> env;
    private final String kind;
    private final Field<String> profileId;
    private final Field<List<String>> shellArgs;
    private final Field<String> terminalId;
    private final Field<String> url;

    private SplitRespawn(Builder builder) {
        this.cwd = builder.cwd;
        this.engine = builder.engine;
        this.env = builder.env.map(value -> Collections.unmodifiableMap(new LinkedHashMap<>(value)));
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.profileId = builder.profileId;
        this.shellArgs = builder.shellArgs.map(value -> List.copyOf(value));
        this.terminalId = builder.terminalId;
        this.url = builder.url;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> cwd() { return cwd; }
    public Field<String> engine() { return engine; }
    public Field<Map<String, String>> env() { return env; }
    public String kind() { return kind; }
    public Field<String> profileId() { return profileId; }
    public Field<List<String>> shellArgs() { return shellArgs; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> url() { return url; }

    public static SplitRespawn fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SplitRespawn");
        Builder builder = builder();
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "SplitRespawn.cwd"));
        }
        Object rawEngine = Wire.optional(object, "engine");
        if (!Wire.isMissing(rawEngine)) {
            builder.engine(rawEngine == null ? null : Wire.string(rawEngine, "SplitRespawn.engine"));
        }
        Object rawEnv = Wire.optional(object, "env");
        if (!Wire.isMissing(rawEnv)) {
            builder.env(rawEnv == null ? null : Wire.map(rawEnv, "SplitRespawn.env", item -> Wire.string(item, "SplitRespawn.env value")));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "SplitRespawn.kind"));
        Object rawProfileId = Wire.optional(object, "profile_id");
        if (!Wire.isMissing(rawProfileId)) {
            builder.profileId(rawProfileId == null ? null : Wire.string(rawProfileId, "SplitRespawn.profile_id"));
        }
        Object rawShellArgs = Wire.optional(object, "shell_args");
        if (!Wire.isMissing(rawShellArgs)) {
            builder.shellArgs(rawShellArgs == null ? null : Wire.array(rawShellArgs, "SplitRespawn.shell_args", item -> Wire.string(item, "SplitRespawn.shell_args item")));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SplitRespawn.terminal_id"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(rawUrl == null ? null : Wire.string(rawUrl, "SplitRespawn.url"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "engine", engine);
        Wire.put(object, "env", env);
        Wire.put(object, "kind", kind);
        Wire.put(object, "profile_id", profileId);
        Wire.put(object, "shell_args", shellArgs);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "url", url);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SplitRespawn that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(engine, that.engine) && Objects.equals(env, that.env) && Objects.equals(kind, that.kind) && Objects.equals(profileId, that.profileId) && Objects.equals(shellArgs, that.shellArgs) && Objects.equals(terminalId, that.terminalId) && Objects.equals(url, that.url);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, engine, env, kind, profileId, shellArgs, terminalId, url); }

    @Override
    public String toString() { return "SplitRespawn" + toWire(); }

    public static final class Builder {
        private Field<String> cwd = Field.omitted();
        private Field<String> engine = Field.omitted();
        private Field<Map<String, String>> env = Field.omitted();
        private String kind;
        private boolean kindSet;
        private Field<String> profileId = Field.omitted();
        private Field<List<String>> shellArgs = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> url = Field.omitted();

        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder engine(String value) {
            this.engine = Field.ofNullable(value);
            return this;
        }
        public Builder env(Map<String, String> value) {
            this.env = Field.ofNullable(value);
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder profileId(String value) {
            this.profileId = Field.ofNullable(value);
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
        public SplitRespawn build() { return new SplitRespawn(this); }
    }
}
