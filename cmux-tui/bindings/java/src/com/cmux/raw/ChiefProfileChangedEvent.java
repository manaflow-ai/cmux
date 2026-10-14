// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable chief-profile-changed event. Protocol v12; streams: subscribe. */
public final class ChiefProfileChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final String avatar;

    private ChiefProfileChangedEvent(Builder builder) {
        if (!builder.avatarSet) throw new IllegalArgumentException("avatar is required");
        this.avatar = builder.avatar;
    }

    public static Builder builder() { return new Builder(); }

    public String avatar() { return avatar; }
    @Override public String event() { return "chief-profile-changed"; }

    public static ChiefProfileChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ChiefProfileChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "chief-profile-changed", "ChiefProfileChangedEvent.event");
        Object rawAvatar = Wire.required(object, "avatar");
        builder.avatar(rawAvatar == null ? null : Wire.string(rawAvatar, "ChiefProfileChangedEvent.avatar"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "chief-profile-changed");
        Wire.put(object, "avatar", avatar);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ChiefProfileChangedEvent that)) return false;
        return Objects.equals(avatar, that.avatar);
    }

    @Override
    public int hashCode() { return Objects.hash(avatar); }

    @Override
    public String toString() { return "ChiefProfileChangedEvent" + toWire(); }

    public static final class Builder {
        private String avatar;
        private boolean avatarSet;

        public Builder avatar(String value) {
            this.avatar = value;
            this.avatarSet = true;
            return this;
        }
        public ChiefProfileChangedEvent build() { return new ChiefProfileChangedEvent(this); }
    }
}
