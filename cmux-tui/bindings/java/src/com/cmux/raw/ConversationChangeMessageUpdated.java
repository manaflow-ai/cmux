// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationChangeMessageUpdated implements WireValue, ConversationChange {
    private final ConversationMessage message;

    private ConversationChangeMessageUpdated(Builder builder) {
        if (!builder.messageSet) throw new IllegalArgumentException("message is required");
        this.message = Wire.nonNull(builder.message, "message");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return "message-updated"; }
    public ConversationMessage message() { return message; }

    public static ConversationChangeMessageUpdated fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationChangeMessageUpdated");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "message-updated", "ConversationChangeMessageUpdated.kind");
        Object rawMessage = Wire.required(object, "message");
        builder.message(ConversationMessage.fromWire(rawMessage));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", "message-updated");
        Wire.put(object, "message", message);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationChangeMessageUpdated that)) return false;
        return Objects.equals(message, that.message);
    }

    @Override
    public int hashCode() { return Objects.hash(message); }

    @Override
    public String toString() { return "ConversationChangeMessageUpdated" + toWire(); }

    public static final class Builder {
        private ConversationMessage message;
        private boolean messageSet;

        public Builder message(ConversationMessage value) {
            this.message = value;
            this.messageSet = true;
            return this;
        }
        public ConversationChangeMessageUpdated build() { return new ConversationChangeMessageUpdated(this); }
    }
}
