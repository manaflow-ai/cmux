// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SavedTabGroupMember implements WireValue {
    /** kind terminal. */
    private final Field<String> cwd;
    /** kind browser. Known values: webkit, cef. */
    private final Field<String> engine;
    /** Known values: terminal (terminal_id, cwd, title) and browser (url, engine, profile_id, title). A member of another kind keeps its fields in the additional properties. */
    private final String kind;
    /** kind browser. */
    private final Field<String> profileId;
    /** kind terminal. */
    private final Field<String> terminalId;
    private final Field<String> title;
    /** kind browser. */
    private final Field<String> url;
    private final Map<String, Object> additionalProperties;

    private SavedTabGroupMember(Builder builder) {
        this.cwd = builder.cwd;
        this.engine = builder.engine;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.profileId = builder.profileId;
        this.terminalId = builder.terminalId;
        this.title = builder.title;
        this.url = builder.url;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> cwd() { return cwd; }
    public Field<String> engine() { return engine; }
    public String kind() { return kind; }
    public Field<String> profileId() { return profileId; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> title() { return title; }
    public Field<String> url() { return url; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static SavedTabGroupMember fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SavedTabGroupMember");
        Builder builder = builder();
        Object rawCwd = Wire.optional(object, "cwd");
        if (!Wire.isMissing(rawCwd)) {
            builder.cwd(rawCwd == null ? null : Wire.string(rawCwd, "SavedTabGroupMember.cwd"));
        }
        Object rawEngine = Wire.optional(object, "engine");
        if (!Wire.isMissing(rawEngine)) {
            builder.engine(rawEngine == null ? null : Wire.string(rawEngine, "SavedTabGroupMember.engine"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "SavedTabGroupMember.kind"));
        Object rawProfileId = Wire.optional(object, "profile_id");
        if (!Wire.isMissing(rawProfileId)) {
            builder.profileId(rawProfileId == null ? null : Wire.string(rawProfileId, "SavedTabGroupMember.profile_id"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SavedTabGroupMember.terminal_id"));
        }
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "SavedTabGroupMember.title"));
        }
        Object rawUrl = Wire.optional(object, "url");
        if (!Wire.isMissing(rawUrl)) {
            builder.url(Wire.string(rawUrl, "SavedTabGroupMember.url"));
        }
        List<String> known = List.of("cwd", "engine", "kind", "profile_id", "terminal_id", "title", "url");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cwd", cwd);
        Wire.put(object, "engine", engine);
        Wire.put(object, "kind", kind);
        Wire.put(object, "profile_id", profileId);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "title", title);
        Wire.put(object, "url", url);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SavedTabGroupMember that)) return false;
        return Objects.equals(cwd, that.cwd) && Objects.equals(engine, that.engine) && Objects.equals(kind, that.kind) && Objects.equals(profileId, that.profileId) && Objects.equals(terminalId, that.terminalId) && Objects.equals(title, that.title) && Objects.equals(url, that.url) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(cwd, engine, kind, profileId, terminalId, title, url, additionalProperties); }

    @Override
    public String toString() { return "SavedTabGroupMember" + toWire(); }

    public static final class Builder {
        private Field<String> cwd = Field.omitted();
        private Field<String> engine = Field.omitted();
        private String kind;
        private boolean kindSet;
        private Field<String> profileId = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> title = Field.omitted();
        private Field<String> url = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder cwd(String value) {
            this.cwd = Field.ofNullable(value);
            return this;
        }
        public Builder engine(String value) {
            this.engine = Field.ofNullable(value);
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
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public Builder url(String value) {
            this.url = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public SavedTabGroupMember build() { return new SavedTabGroupMember(this); }
    }
}
