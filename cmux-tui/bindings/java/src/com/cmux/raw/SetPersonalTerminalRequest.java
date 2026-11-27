// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-personal-terminal request. Protocol v12; authority: control. */
public final class SetPersonalTerminalRequest implements WireValue {
    private final String sessionId;
    private final String terminalKey;
    private final Field<String> theme;

    private SetPersonalTerminalRequest(Builder builder) {
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        if (!builder.terminalKeySet) throw new IllegalArgumentException("terminal_key is required");
        this.terminalKey = Wire.nonNull(builder.terminalKey, "terminal_key");
        this.theme = builder.theme;
    }

    public static Builder builder() { return new Builder(); }

    public String sessionId() { return sessionId; }
    public String terminalKey() { return terminalKey; }
    public Field<String> theme() { return theme; }

    public static SetPersonalTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetPersonalTerminalRequest");
        Builder builder = builder();
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "SetPersonalTerminalRequest.session_id"));
        Object rawTerminalKey = Wire.required(object, "terminal_key");
        builder.terminalKey(Wire.string(rawTerminalKey, "SetPersonalTerminalRequest.terminal_key"));
        Object rawTheme = Wire.optional(object, "theme");
        if (!Wire.isMissing(rawTheme)) {
            builder.theme(rawTheme == null ? null : Wire.string(rawTheme, "SetPersonalTerminalRequest.theme"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "terminal_key", terminalKey);
        Wire.put(object, "theme", theme);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetPersonalTerminalRequest that)) return false;
        return Objects.equals(sessionId, that.sessionId) && Objects.equals(terminalKey, that.terminalKey) && Objects.equals(theme, that.theme);
    }

    @Override
    public int hashCode() { return Objects.hash(sessionId, terminalKey, theme); }

    @Override
    public String toString() { return "SetPersonalTerminalRequest" + toWire(); }

    public static final class Builder {
        private String sessionId;
        private boolean sessionIdSet;
        private String terminalKey;
        private boolean terminalKeySet;
        private Field<String> theme = Field.omitted();

        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder terminalKey(String value) {
            this.terminalKey = value;
            this.terminalKeySet = true;
            return this;
        }
        public Builder theme(String value) {
            this.theme = Field.ofNullable(value);
            return this;
        }
        public SetPersonalTerminalRequest build() { return new SetPersonalTerminalRequest(this); }
    }
}
