// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-environment request. Protocol v12; authority: local-admin. */
public final class CloudEnvironmentRequest implements WireValue {
    private final String accessToken;
    private final String action;
    private final Object params;
    private final String platformOrigin;

    private CloudEnvironmentRequest(Builder builder) {
        if (!builder.accessTokenSet) throw new IllegalArgumentException("access_token is required");
        this.accessToken = Wire.nonNull(builder.accessToken, "access_token");
        if (!builder.actionSet) throw new IllegalArgumentException("action is required");
        this.action = Wire.nonNull(builder.action, "action");
        if (!builder.paramsSet) throw new IllegalArgumentException("params is required");
        this.params = builder.params == null ? null : Wire.immutableJson(builder.params);
        if (!builder.platformOriginSet) throw new IllegalArgumentException("platform_origin is required");
        this.platformOrigin = Wire.nonNull(builder.platformOrigin, "platform_origin");
    }

    public static Builder builder() { return new Builder(); }

    public String accessToken() { return accessToken; }
    public String action() { return action; }
    public Object params() { return params; }
    public String platformOrigin() { return platformOrigin; }

    public static CloudEnvironmentRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudEnvironmentRequest");
        Builder builder = builder();
        Object rawAccessToken = Wire.required(object, "access_token");
        builder.accessToken(Wire.string(rawAccessToken, "CloudEnvironmentRequest.access_token"));
        Object rawAction = Wire.required(object, "action");
        builder.action(Wire.string(rawAction, "CloudEnvironmentRequest.action"));
        Object rawParams = Wire.required(object, "params");
        builder.params(rawParams == null ? null : Wire.immutableJson(rawParams));
        Object rawPlatformOrigin = Wire.required(object, "platform_origin");
        builder.platformOrigin(Wire.string(rawPlatformOrigin, "CloudEnvironmentRequest.platform_origin"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "access_token", accessToken);
        Wire.put(object, "action", action);
        Wire.put(object, "params", params);
        Wire.put(object, "platform_origin", platformOrigin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudEnvironmentRequest that)) return false;
        return Objects.equals(accessToken, that.accessToken) && Objects.equals(action, that.action) && Objects.equals(params, that.params) && Objects.equals(platformOrigin, that.platformOrigin);
    }

    @Override
    public int hashCode() { return Objects.hash(accessToken, action, params, platformOrigin); }

    @Override
    public String toString() { return "CloudEnvironmentRequest" + toWire(); }

    public static final class Builder {
        private String accessToken;
        private boolean accessTokenSet;
        private String action;
        private boolean actionSet;
        private Object params;
        private boolean paramsSet;
        private String platformOrigin;
        private boolean platformOriginSet;

        public Builder accessToken(String value) {
            this.accessToken = value;
            this.accessTokenSet = true;
            return this;
        }
        public Builder action(String value) {
            this.action = value;
            this.actionSet = true;
            return this;
        }
        public Builder params(Object value) {
            this.params = value;
            this.paramsSet = true;
            return this;
        }
        public Builder platformOrigin(String value) {
            this.platformOrigin = value;
            this.platformOriginSet = true;
            return this;
        }
        public CloudEnvironmentRequest build() { return new CloudEnvironmentRequest(this); }
    }
}
