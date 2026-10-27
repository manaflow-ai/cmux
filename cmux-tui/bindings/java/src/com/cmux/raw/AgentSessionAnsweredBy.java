// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionAnsweredBy implements WireValue {
    /** The device the person answered on: 1 to 128 of [A-Za-z0-9_.:-]. */
    private final String device;
    /** The feed item the person answered: 1 to 128 of [A-Za-z0-9_.:-]. */
    private final String feedItem;

    private AgentSessionAnsweredBy(Builder builder) {
        if (!builder.deviceSet) throw new IllegalArgumentException("device is required");
        this.device = Wire.nonNull(builder.device, "device");
        if (!builder.feedItemSet) throw new IllegalArgumentException("feed_item is required");
        this.feedItem = Wire.nonNull(builder.feedItem, "feed_item");
    }

    public static Builder builder() { return new Builder(); }

    public String device() { return device; }
    public String feedItem() { return feedItem; }

    public static AgentSessionAnsweredBy fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionAnsweredBy");
        Builder builder = builder();
        Object rawDevice = Wire.required(object, "device");
        builder.device(Wire.string(rawDevice, "AgentSessionAnsweredBy.device"));
        Object rawFeedItem = Wire.required(object, "feed_item");
        builder.feedItem(Wire.string(rawFeedItem, "AgentSessionAnsweredBy.feed_item"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "device", device);
        Wire.put(object, "feed_item", feedItem);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionAnsweredBy that)) return false;
        return Objects.equals(device, that.device) && Objects.equals(feedItem, that.feedItem);
    }

    @Override
    public int hashCode() { return Objects.hash(device, feedItem); }

    @Override
    public String toString() { return "AgentSessionAnsweredBy" + toWire(); }

    public static final class Builder {
        private String device;
        private boolean deviceSet;
        private String feedItem;
        private boolean feedItemSet;

        public Builder device(String value) {
            this.device = value;
            this.deviceSet = true;
            return this;
        }
        public Builder feedItem(String value) {
            this.feedItem = value;
            this.feedItemSet = true;
            return this;
        }
        public AgentSessionAnsweredBy build() { return new AgentSessionAnsweredBy(this); }
    }
}
