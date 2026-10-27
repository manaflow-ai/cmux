// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable script-repl-close request. Protocol v12; authority: local-admin. */
public final class ScriptReplCloseRequest implements WireValue {
    private final String session;

    private ScriptReplCloseRequest(Builder builder) {
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
    }

    public static Builder builder() { return new Builder(); }

    public String session() { return session; }

    public static ScriptReplCloseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptReplCloseRequest");
        Builder builder = builder();
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "ScriptReplCloseRequest.session"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptReplCloseRequest that)) return false;
        return Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(session); }

    @Override
    public String toString() { return "ScriptReplCloseRequest" + toWire(); }

    public static final class Builder {
        private String session;
        private boolean sessionSet;

        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public ScriptReplCloseRequest build() { return new ScriptReplCloseRequest(this); }
    }
}
