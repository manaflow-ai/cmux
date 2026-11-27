// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-remote-terminal-tab request. Protocol v12; authority: control. */
public final class NewRemoteTerminalTabRequest implements WireValue {
    private final Field<Integer> cols;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;
    private final String sessionId;
    private final String sessionName;
    private final String terminalId;
    private final Field<String> title;

    private NewRemoteTerminalTabRequest(Builder builder) {
        this.cols = builder.cols;
        this.pane = builder.pane;
        this.rows = builder.rows;
        if (!builder.sessionIdSet) throw new IllegalArgumentException("session_id is required");
        this.sessionId = Wire.nonNull(builder.sessionId, "session_id");
        if (!builder.sessionNameSet) throw new IllegalArgumentException("session_name is required");
        this.sessionName = Wire.nonNull(builder.sessionName, "session_name");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        this.title = builder.title;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> cols() { return cols; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public String sessionId() { return sessionId; }
    public String sessionName() { return sessionName; }
    public String terminalId() { return terminalId; }
    public Field<String> title() { return title; }

    public static NewRemoteTerminalTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewRemoteTerminalTabRequest");
        Builder builder = builder();
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewRemoteTerminalTabRequest.cols"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewRemoteTerminalTabRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewRemoteTerminalTabRequest.rows"));
        }
        Object rawSessionId = Wire.required(object, "session_id");
        builder.sessionId(Wire.string(rawSessionId, "NewRemoteTerminalTabRequest.session_id"));
        Object rawSessionName = Wire.required(object, "session_name");
        builder.sessionName(Wire.string(rawSessionName, "NewRemoteTerminalTabRequest.session_name"));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "NewRemoteTerminalTabRequest.terminal_id"));
        Object rawTitle = Wire.optional(object, "title");
        if (!Wire.isMissing(rawTitle)) {
            builder.title(rawTitle == null ? null : Wire.string(rawTitle, "NewRemoteTerminalTabRequest.title"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "session_id", sessionId);
        Wire.put(object, "session_name", sessionName);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewRemoteTerminalTabRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(sessionId, that.sessionId) && Objects.equals(sessionName, that.sessionName) && Objects.equals(terminalId, that.terminalId) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, pane, rows, sessionId, sessionName, terminalId, title); }

    @Override
    public String toString() { return "NewRemoteTerminalTabRequest" + toWire(); }

    public static final class Builder {
        private Field<Integer> cols = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private String sessionId;
        private boolean sessionIdSet;
        private String sessionName;
        private boolean sessionNameSet;
        private String terminalId;
        private boolean terminalIdSet;
        private Field<String> title = Field.omitted();

        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder sessionId(String value) {
            this.sessionId = value;
            this.sessionIdSet = true;
            return this;
        }
        public Builder sessionName(String value) {
            this.sessionName = value;
            this.sessionNameSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = Field.ofNullable(value);
            return this;
        }
        public NewRemoteTerminalTabRequest build() { return new NewRemoteTerminalTabRequest(this); }
    }
}
