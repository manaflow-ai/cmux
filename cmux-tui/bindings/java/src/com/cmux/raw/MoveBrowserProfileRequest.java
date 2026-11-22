// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-browser-profile request. Protocol v12; authority: control. */
public final class MoveBrowserProfileRequest implements WireValue {
    private final String browserProfile;
    private final UInt64 index;

    private MoveBrowserProfileRequest(Builder builder) {
        if (!builder.browserProfileSet) throw new IllegalArgumentException("browser_profile is required");
        this.browserProfile = Wire.nonNull(builder.browserProfile, "browser_profile");
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfile() { return browserProfile; }
    public UInt64 index() { return index; }

    public static MoveBrowserProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveBrowserProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfile = Wire.required(object, "browser_profile");
        builder.browserProfile(Wire.string(rawBrowserProfile, "MoveBrowserProfileRequest.browser_profile"));
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveBrowserProfileRequest.index"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile", browserProfile);
        Wire.put(object, "index", index);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveBrowserProfileRequest that)) return false;
        return Objects.equals(browserProfile, that.browserProfile) && Objects.equals(index, that.index);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfile, index); }

    @Override
    public String toString() { return "MoveBrowserProfileRequest" + toWire(); }

    public static final class Builder {
        private String browserProfile;
        private boolean browserProfileSet;
        private UInt64 index;
        private boolean indexSet;

        public Builder browserProfile(String value) {
            this.browserProfile = value;
            this.browserProfileSet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public MoveBrowserProfileRequest build() { return new MoveBrowserProfileRequest(this); }
    }
}
