// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable bind-conversation-tab-session request. Protocol v12; authority: control. */
public final class BindConversationTabSessionRequest implements WireValue {
    private final String session;
    private final UInt64 surface;

    private BindConversationTabSessionRequest(Builder builder) {
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public String session() { return session; }
    public UInt64 surface() { return surface; }

    public static BindConversationTabSessionRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "BindConversationTabSessionRequest");
        Builder builder = builder();
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "BindConversationTabSessionRequest.session"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "BindConversationTabSessionRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "session", session);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof BindConversationTabSessionRequest that)) return false;
        return Objects.equals(session, that.session) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(session, surface); }

    @Override
    public String toString() { return "BindConversationTabSessionRequest" + toWire(); }

    public static final class Builder {
        private String session;
        private boolean sessionSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public BindConversationTabSessionRequest build() { return new BindConversationTabSessionRequest(this); }
    }
}
