// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-local-list request. Protocol v12; authority: control. */
public final class FeedLocalListRequest implements WireValue {
    private final Field<String> state;
    private final Field<String> terminalId;
    private final Field<Boolean> unread;

    private FeedLocalListRequest(Builder builder) {
        this.state = builder.state;
        this.terminalId = builder.terminalId;
        this.unread = builder.unread;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> state() { return state; }
    public Field<String> terminalId() { return terminalId; }
    public Field<Boolean> unread() { return unread; }

    public static FeedLocalListRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedLocalListRequest");
        Builder builder = builder();
        Object rawState = Wire.optional(object, "state");
        if (!Wire.isMissing(rawState)) {
            builder.state(rawState == null ? null : Wire.string(rawState, "FeedLocalListRequest.state"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "FeedLocalListRequest.terminal_id"));
        }
        Object rawUnread = Wire.optional(object, "unread");
        if (!Wire.isMissing(rawUnread)) {
            builder.unread(Wire.bool(rawUnread, "FeedLocalListRequest.unread"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "state", state);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "unread", unread);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedLocalListRequest that)) return false;
        return Objects.equals(state, that.state) && Objects.equals(terminalId, that.terminalId) && Objects.equals(unread, that.unread);
    }

    @Override
    public int hashCode() { return Objects.hash(state, terminalId, unread); }

    @Override
    public String toString() { return "FeedLocalListRequest" + toWire(); }

    public static final class Builder {
        private Field<String> state = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<Boolean> unread = Field.omitted();

        public Builder state(String value) {
            this.state = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder unread(Boolean value) {
            this.unread = Field.of(value);
            return this;
        }
        public FeedLocalListRequest build() { return new FeedLocalListRequest(this); }
    }
}
