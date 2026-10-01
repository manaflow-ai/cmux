// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable delete-browser-profile request. Protocol v12; authority: control. */
public final class DeleteBrowserProfileRequest implements WireValue {
    private final String browserProfile;

    private DeleteBrowserProfileRequest(Builder builder) {
        if (!builder.browserProfileSet) throw new IllegalArgumentException("browser_profile is required");
        this.browserProfile = Wire.nonNull(builder.browserProfile, "browser_profile");
    }

    public static Builder builder() { return new Builder(); }

    public String browserProfile() { return browserProfile; }

    public static DeleteBrowserProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteBrowserProfileRequest");
        Builder builder = builder();
        Object rawBrowserProfile = Wire.required(object, "browser_profile");
        builder.browserProfile(Wire.string(rawBrowserProfile, "DeleteBrowserProfileRequest.browser_profile"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "browser_profile", browserProfile);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteBrowserProfileRequest that)) return false;
        return Objects.equals(browserProfile, that.browserProfile);
    }

    @Override
    public int hashCode() { return Objects.hash(browserProfile); }

    @Override
    public String toString() { return "DeleteBrowserProfileRequest" + toWire(); }

    public static final class Builder {
        private String browserProfile;
        private boolean browserProfileSet;

        public Builder browserProfile(String value) {
            this.browserProfile = value;
            this.browserProfileSet = true;
            return this;
        }
        public DeleteBrowserProfileRequest build() { return new DeleteBrowserProfileRequest(this); }
    }
}
