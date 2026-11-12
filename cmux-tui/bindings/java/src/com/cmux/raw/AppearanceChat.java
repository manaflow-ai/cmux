// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppearanceChat implements WireValue {
    private final Object received;
    private final Object receivedText;
    private final Object sent;
    private final Object sentText;

    private AppearanceChat(Builder builder) {
        if (!builder.receivedSet) throw new IllegalArgumentException("received is required");
        this.received = builder.received == null ? null : Wire.immutableJson(builder.received);
        if (!builder.receivedTextSet) throw new IllegalArgumentException("received_text is required");
        this.receivedText = builder.receivedText == null ? null : Wire.immutableJson(builder.receivedText);
        if (!builder.sentSet) throw new IllegalArgumentException("sent is required");
        this.sent = builder.sent == null ? null : Wire.immutableJson(builder.sent);
        if (!builder.sentTextSet) throw new IllegalArgumentException("sent_text is required");
        this.sentText = builder.sentText == null ? null : Wire.immutableJson(builder.sentText);
    }

    public static Builder builder() { return new Builder(); }

    public Object received() { return received; }
    public Object receivedText() { return receivedText; }
    public Object sent() { return sent; }
    public Object sentText() { return sentText; }

    public static AppearanceChat fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppearanceChat");
        Builder builder = builder();
        Object rawReceived = Wire.required(object, "received");
        builder.received(rawReceived == null ? null : Wire.immutableJson(rawReceived));
        Object rawReceivedText = Wire.required(object, "received_text");
        builder.receivedText(rawReceivedText == null ? null : Wire.immutableJson(rawReceivedText));
        Object rawSent = Wire.required(object, "sent");
        builder.sent(rawSent == null ? null : Wire.immutableJson(rawSent));
        Object rawSentText = Wire.required(object, "sent_text");
        builder.sentText(rawSentText == null ? null : Wire.immutableJson(rawSentText));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "received", received);
        Wire.put(object, "received_text", receivedText);
        Wire.put(object, "sent", sent);
        Wire.put(object, "sent_text", sentText);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppearanceChat that)) return false;
        return Objects.equals(received, that.received) && Objects.equals(receivedText, that.receivedText) && Objects.equals(sent, that.sent) && Objects.equals(sentText, that.sentText);
    }

    @Override
    public int hashCode() { return Objects.hash(received, receivedText, sent, sentText); }

    @Override
    public String toString() { return "AppearanceChat" + toWire(); }

    public static final class Builder {
        private Object received;
        private boolean receivedSet;
        private Object receivedText;
        private boolean receivedTextSet;
        private Object sent;
        private boolean sentSet;
        private Object sentText;
        private boolean sentTextSet;

        public Builder received(Object value) {
            this.received = value;
            this.receivedSet = true;
            return this;
        }
        public Builder receivedText(Object value) {
            this.receivedText = value;
            this.receivedTextSet = true;
            return this;
        }
        public Builder sent(Object value) {
            this.sent = value;
            this.sentSet = true;
            return this;
        }
        public Builder sentText(Object value) {
            this.sentText = value;
            this.sentTextSet = true;
            return this;
        }
        public AppearanceChat build() { return new AppearanceChat(this); }
    }
}
