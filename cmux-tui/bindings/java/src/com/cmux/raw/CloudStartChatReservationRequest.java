// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-start-chat-reservation request. Protocol v12; authority: local-admin. */
public final class CloudStartChatReservationRequest implements WireValue {
    private final String accessToken;
    private final String installToken;
    private final boolean release;
    private final Object request;

    private CloudStartChatReservationRequest(Builder builder) {
        if (!builder.accessTokenSet) throw new IllegalArgumentException("access_token is required");
        this.accessToken = Wire.nonNull(builder.accessToken, "access_token");
        if (!builder.installTokenSet) throw new IllegalArgumentException("install_token is required");
        this.installToken = Wire.nonNull(builder.installToken, "install_token");
        if (!builder.releaseSet) throw new IllegalArgumentException("release is required");
        this.release = builder.release;
        if (!builder.requestSet) throw new IllegalArgumentException("request is required");
        this.request = builder.request == null ? null : Wire.immutableJson(builder.request);
    }

    public static Builder builder() { return new Builder(); }

    public String accessToken() { return accessToken; }
    public String installToken() { return installToken; }
    public boolean release() { return release; }
    public Object request() { return request; }

    public static CloudStartChatReservationRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudStartChatReservationRequest");
        Builder builder = builder();
        Object rawAccessToken = Wire.required(object, "access_token");
        builder.accessToken(Wire.string(rawAccessToken, "CloudStartChatReservationRequest.access_token"));
        Object rawInstallToken = Wire.required(object, "install_token");
        builder.installToken(Wire.string(rawInstallToken, "CloudStartChatReservationRequest.install_token"));
        Object rawRelease = Wire.required(object, "release");
        builder.release(Wire.bool(rawRelease, "CloudStartChatReservationRequest.release"));
        Object rawRequest = Wire.required(object, "request");
        builder.request(rawRequest == null ? null : Wire.immutableJson(rawRequest));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "access_token", accessToken);
        Wire.put(object, "install_token", installToken);
        Wire.put(object, "release", release);
        Wire.put(object, "request", request);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudStartChatReservationRequest that)) return false;
        return Objects.equals(accessToken, that.accessToken) && Objects.equals(installToken, that.installToken) && Objects.equals(release, that.release) && Objects.equals(request, that.request);
    }

    @Override
    public int hashCode() { return Objects.hash(accessToken, installToken, release, request); }

    @Override
    public String toString() { return "CloudStartChatReservationRequest" + toWire(); }

    public static final class Builder {
        private String accessToken;
        private boolean accessTokenSet;
        private String installToken;
        private boolean installTokenSet;
        private Boolean release;
        private boolean releaseSet;
        private Object request;
        private boolean requestSet;

        public Builder accessToken(String value) {
            this.accessToken = value;
            this.accessTokenSet = true;
            return this;
        }
        public Builder installToken(String value) {
            this.installToken = value;
            this.installTokenSet = true;
            return this;
        }
        public Builder release(boolean value) {
            this.release = value;
            this.releaseSet = true;
            return this;
        }
        public Builder request(Object value) {
            this.request = value;
            this.requestSet = true;
            return this;
        }
        public CloudStartChatReservationRequest build() { return new CloudStartChatReservationRequest(this); }
    }
}
