// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable script-log event. Protocol v12; streams: control. */
public final class ScriptLogEvent implements WireValue, ProtocolEvent {
    /** The console method that wrote the line (log, info, warn, error, debug). */
    private final String level;
    /** The line, its arguments joined as the console prints them. */
    private final String message;
    /** The id of the script-run that wrote the line; absent for a REPL session's line. */
    private final Field<Object> request;
    /** The REPL session (script-repl-open) whose cell wrote the line; absent for a script-run's line. */
    private final Field<String> session;

    private ScriptLogEvent(Builder builder) {
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
        if (!builder.messageSet) throw new IllegalArgumentException("message is required");
        this.message = Wire.nonNull(builder.message, "message");
        this.request = builder.request.map(value -> Wire.immutableJson(value));
        this.session = builder.session;
    }

    public static Builder builder() { return new Builder(); }

    public String level() { return level; }
    public String message() { return message; }
    public Field<Object> request() { return request; }
    public Field<String> session() { return session; }
    @Override public String event() { return "script-log"; }

    public static ScriptLogEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScriptLogEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "script-log", "ScriptLogEvent.event");
        Object rawLevel = Wire.required(object, "level");
        builder.level(Wire.string(rawLevel, "ScriptLogEvent.level"));
        Object rawMessage = Wire.required(object, "message");
        builder.message(Wire.string(rawMessage, "ScriptLogEvent.message"));
        Object rawRequest = Wire.optional(object, "request");
        if (!Wire.isMissing(rawRequest)) {
            builder.request(Wire.immutableJson(rawRequest));
        }
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(Wire.string(rawSession, "ScriptLogEvent.session"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "script-log");
        Wire.put(object, "level", level);
        Wire.put(object, "message", message);
        Wire.put(object, "request", request);
        Wire.put(object, "session", session);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScriptLogEvent that)) return false;
        return Objects.equals(level, that.level) && Objects.equals(message, that.message) && Objects.equals(request, that.request) && Objects.equals(session, that.session);
    }

    @Override
    public int hashCode() { return Objects.hash(level, message, request, session); }

    @Override
    public String toString() { return "ScriptLogEvent" + toWire(); }

    public static final class Builder {
        private String level;
        private boolean levelSet;
        private String message;
        private boolean messageSet;
        private Field<Object> request = Field.omitted();
        private Field<String> session = Field.omitted();

        public Builder level(String value) {
            this.level = value;
            this.levelSet = true;
            return this;
        }
        public Builder message(String value) {
            this.message = value;
            this.messageSet = true;
            return this;
        }
        public Builder request(Object value) {
            this.request = Field.of(value);
            return this;
        }
        public Builder session(String value) {
            this.session = Field.of(value);
            return this;
        }
        public ScriptLogEvent build() { return new ScriptLogEvent(this); }
    }
}
