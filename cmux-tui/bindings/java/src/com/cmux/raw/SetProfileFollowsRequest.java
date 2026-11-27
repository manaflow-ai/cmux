// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-profile-follows request. Protocol v12; authority: control. */
public final class SetProfileFollowsRequest implements WireValue {
    private final String profile;
    private final List<String> sessionIds;

    private SetProfileFollowsRequest(Builder builder) {
        if (!builder.profileSet) throw new IllegalArgumentException("profile is required");
        this.profile = Wire.nonNull(builder.profile, "profile");
        if (!builder.sessionIdsSet) throw new IllegalArgumentException("session_ids is required");
        this.sessionIds = List.copyOf(Wire.nonNull(builder.sessionIds, "session_ids"));
    }

    public static Builder builder() { return new Builder(); }

    public String profile() { return profile; }
    public List<String> sessionIds() { return sessionIds; }

    public static SetProfileFollowsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetProfileFollowsRequest");
        Builder builder = builder();
        Object rawProfile = Wire.required(object, "profile");
        builder.profile(Wire.string(rawProfile, "SetProfileFollowsRequest.profile"));
        Object rawSessionIds = Wire.required(object, "session_ids");
        builder.sessionIds(Wire.array(rawSessionIds, "SetProfileFollowsRequest.session_ids", item -> Wire.string(item, "SetProfileFollowsRequest.session_ids item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "profile", profile);
        Wire.put(object, "session_ids", sessionIds);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetProfileFollowsRequest that)) return false;
        return Objects.equals(profile, that.profile) && Objects.equals(sessionIds, that.sessionIds);
    }

    @Override
    public int hashCode() { return Objects.hash(profile, sessionIds); }

    @Override
    public String toString() { return "SetProfileFollowsRequest" + toWire(); }

    public static final class Builder {
        private String profile;
        private boolean profileSet;
        private List<String> sessionIds;
        private boolean sessionIdsSet;

        public Builder profile(String value) {
            this.profile = value;
            this.profileSet = true;
            return this;
        }
        public Builder sessionIds(List<String> value) {
            this.sessionIds = value;
            this.sessionIdsSet = true;
            return this;
        }
        public SetProfileFollowsRequest build() { return new SetProfileFollowsRequest(this); }
    }
}
