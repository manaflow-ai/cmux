// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-session-icon request. Protocol v12; authority: control. */
public final class SetSessionIconRequest implements WireValue {
    /** An icon value sets the session's (machine's) icon; null clears it. */
    private final String icon;
    private final String sessionId;

    private SetSessionIconRequest(Builder builder) {
        if (!builder.iconSet) throw new IllegalArgumentException("icon is required");
        this.icon = builder.icon;
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
    }

    public static Builder builder() { return new Builder(); }

    public String icon() { return icon; }
    public String sessionId() { return sessionId; }

    public static SetSessionIconRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSessionIconRequest");
        Builder builder = builder();
        Object rawIcon = Wire.required(object, "icon");
        builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "SetSessionIconRequest.icon"));
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "SetSessionIconRequest.session_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "icon", icon);
        Wire.put(object, "session_id", sessionId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSessionIconRequest that)) return false;
        return Objects.equals(icon, that.icon) && Objects.equals(sessionId, that.sessionId);
    }

    @Override
    public int hashCode() { return Objects.hash(icon, sessionId); }

    @Override
    public String toString() { return "SetSessionIconRequest" + toWire(); }

    public static final class Builder {
        private String icon;
        private boolean iconSet;
        private String sessionId;
        private boolean sessionIdSet;

        public Builder icon(String value) {
            this.icon = value;
            this.iconSet = true;
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public SetSessionIconRequest build() { return new SetSessionIconRequest(this); }
    }
}
