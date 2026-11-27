// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-clipboard-reply request. Protocol v12; authority: frontend. */
public final class TerminalClipboardReplyRequest implements WireValue {
    private final String requestId;
    private final Field<String> text;

    private TerminalClipboardReplyRequest(Builder builder) {
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
        this.text = builder.text;
    }

    public static Builder builder() { return new Builder(); }

    public String requestId() { return requestId; }
    public Field<String> text() { return text; }

    public static TerminalClipboardReplyRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalClipboardReplyRequest");
        Builder builder = builder();
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.string(rawRequestId, "TerminalClipboardReplyRequest.request_id"));
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(rawText == null ? null : Wire.string(rawText, "TerminalClipboardReplyRequest.text"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalClipboardReplyRequest that)) return false;
        return Objects.equals(requestId, that.requestId) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(requestId, text); }

    @Override
    public String toString() { return "TerminalClipboardReplyRequest" + toWire(); }

    public static final class Builder {
        private String requestId;
        private boolean requestIdSet;
        private Field<String> text = Field.omitted();

        public Builder requestId(String value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = Field.ofNullable(value);
            return this;
        }
        public TerminalClipboardReplyRequest build() { return new TerminalClipboardReplyRequest(this); }
    }
}
