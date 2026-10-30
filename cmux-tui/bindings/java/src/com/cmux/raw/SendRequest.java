// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable send request. Protocol v5; authority: control. */
public final class SendRequest implements WireValue {
    private final Field<Bytes> bytes;
    private final Field<SendExpectAgent> expectAgent;
    private final Field<String> expectForeground;
    private final Field<UInt64> flow;
    private final Field<Boolean> paste;
    private final Field<Boolean> submit;
    private final Field<UInt64> surface;
    private final Field<String> terminalId;
    private final Field<String> text;

    private SendRequest(Builder builder) {
        this.bytes = builder.bytes;
        this.expectAgent = builder.expectAgent;
        this.expectForeground = builder.expectForeground;
        this.flow = builder.flow;
        this.paste = builder.paste;
        this.submit = builder.submit;
        this.surface = builder.surface;
        this.terminalId = builder.terminalId;
        this.text = builder.text;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Bytes> bytes() { return bytes; }
    public Field<SendExpectAgent> expectAgent() { return expectAgent; }
    public Field<String> expectForeground() { return expectForeground; }
    public Field<UInt64> flow() { return flow; }
    public Field<Boolean> paste() { return paste; }
    public Field<Boolean> submit() { return submit; }
    public Field<UInt64> surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> text() { return text; }

    public static SendRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SendRequest");
        Builder builder = builder();
        Object rawBytes = Wire.optional(object, "bytes");
        if (!Wire.isMissing(rawBytes)) {
            builder.bytes(rawBytes == null ? null : Wire.bytes(rawBytes, "SendRequest.bytes"));
        }
        Object rawExpectAgent = Wire.optional(object, "expect_agent");
        if (!Wire.isMissing(rawExpectAgent)) {
            builder.expectAgent(rawExpectAgent == null ? null : SendExpectAgent.fromWire(rawExpectAgent));
        }
        Object rawExpectForeground = Wire.optional(object, "expect_foreground");
        if (!Wire.isMissing(rawExpectForeground)) {
            builder.expectForeground(rawExpectForeground == null ? null : Wire.string(rawExpectForeground, "SendRequest.expect_foreground"));
        }
        Object rawFlow = Wire.optional(object, "flow");
        if (!Wire.isMissing(rawFlow)) {
            builder.flow(rawFlow == null ? null : Wire.uint64(rawFlow, "SendRequest.flow"));
        }
        Object rawPaste = Wire.optional(object, "paste");
        if (!Wire.isMissing(rawPaste)) {
            builder.paste(Wire.bool(rawPaste, "SendRequest.paste"));
        }
        Object rawSubmit = Wire.optional(object, "submit");
        if (!Wire.isMissing(rawSubmit)) {
            builder.submit(Wire.bool(rawSubmit, "SendRequest.submit"));
        }
        Object rawSurface = Wire.optional(object, "surface");
        if (!Wire.isMissing(rawSurface)) {
            builder.surface(rawSurface == null ? null : Wire.uint64(rawSurface, "SendRequest.surface"));
        }
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "SendRequest.terminal_id"));
        }
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(rawText == null ? null : Wire.string(rawText, "SendRequest.text"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "expect_agent", expectAgent);
        Wire.put(object, "expect_foreground", expectForeground);
        Wire.put(object, "flow", flow);
        Wire.put(object, "paste", paste);
        Wire.put(object, "submit", submit);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SendRequest that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(expectAgent, that.expectAgent) && Objects.equals(expectForeground, that.expectForeground) && Objects.equals(flow, that.flow) && Objects.equals(paste, that.paste) && Objects.equals(submit, that.submit) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, expectAgent, expectForeground, flow, paste, submit, surface, terminalId, text); }

    @Override
    public String toString() { return "SendRequest" + toWire(); }

    public static final class Builder {
        private Field<Bytes> bytes = Field.omitted();
        private Field<SendExpectAgent> expectAgent = Field.omitted();
        private Field<String> expectForeground = Field.omitted();
        private Field<UInt64> flow = Field.omitted();
        private Field<Boolean> paste = Field.omitted();
        private Field<Boolean> submit = Field.omitted();
        private Field<UInt64> surface = Field.omitted();
        private Field<String> terminalId = Field.omitted();
        private Field<String> text = Field.omitted();

        public Builder bytes(Bytes value) {
            this.bytes = Field.ofNullable(value);
            return this;
        }
        public Builder expectAgent(SendExpectAgent value) {
            this.expectAgent = Field.ofNullable(value);
            return this;
        }
        public Builder expectForeground(String value) {
            this.expectForeground = Field.ofNullable(value);
            return this;
        }
        public Builder flow(UInt64 value) {
            this.flow = Field.ofNullable(value);
            return this;
        }
        public Builder paste(Boolean value) {
            this.paste = Field.of(value);
            return this;
        }
        public Builder submit(Boolean value) {
            this.submit = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder text(String value) {
            this.text = Field.ofNullable(value);
            return this;
        }
        public SendRequest build() { return new SendRequest(this); }
    }
}
