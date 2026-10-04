// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-subscription-state event. Protocol v12; streams: subscribe. */
public final class CloudSubscriptionStateEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<String> conversation;
    private final Field<String> reason;
    private final String scope;
    private final String state;

    private CloudSubscriptionStateEvent(Builder builder) {
        this.conversation = builder.conversation;
        this.reason = builder.reason;
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> conversation() { return conversation; }
    public Field<String> reason() { return reason; }
    public String scope() { return scope; }
    public String state() { return state; }
    @Override public String event() { return "cloud-subscription-state"; }

    public static CloudSubscriptionStateEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSubscriptionStateEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "cloud-subscription-state", "CloudSubscriptionStateEvent.event");
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "CloudSubscriptionStateEvent.conversation"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "CloudSubscriptionStateEvent.reason"));
        }
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "CloudSubscriptionStateEvent.scope"));
        Object rawState = Wire.required(object, "state");
        builder.state(Wire.string(rawState, "CloudSubscriptionStateEvent.state"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "cloud-subscription-state");
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "reason", reason);
        Wire.put(object, "scope", scope);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSubscriptionStateEvent that)) return false;
        return Objects.equals(conversation, that.conversation) && Objects.equals(reason, that.reason) && Objects.equals(scope, that.scope) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(conversation, reason, scope, state); }

    @Override
    public String toString() { return "CloudSubscriptionStateEvent" + toWire(); }

    public static final class Builder {
        private Field<String> conversation = Field.omitted();
        private Field<String> reason = Field.omitted();
        private String scope;
        private boolean scopeSet;
        private String state;
        private boolean stateSet;

        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder scope(String value) {
            this.scope = value;
            this.scopeSet = true;
            return this;
        }
        public Builder state(String value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public CloudSubscriptionStateEvent build() { return new CloudSubscriptionStateEvent(this); }
    }
}
