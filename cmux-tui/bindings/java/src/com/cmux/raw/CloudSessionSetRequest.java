// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-session-set request. Protocol v12; authority: local-admin. */
public final class CloudSessionSetRequest implements WireValue {
    private final Field<String> accessToken;
    private final String apiBaseUrl;
    private final Field<String> auth;
    private final Field<String> clientVersion;
    private final Field<UInt64> expiresAt;

    private CloudSessionSetRequest(Builder builder) {
        this.accessToken = builder.accessToken;
        if (!builder.apiBaseUrlSet) throw new IllegalArgumentException("api_base_url is required");
        this.apiBaseUrl = Wire.nonNull(builder.apiBaseUrl, "api_base_url");
        this.auth = builder.auth;
        this.clientVersion = builder.clientVersion;
        this.expiresAt = builder.expiresAt;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> accessToken() { return accessToken; }
    public String apiBaseUrl() { return apiBaseUrl; }
    public Field<String> auth() { return auth; }
    public Field<String> clientVersion() { return clientVersion; }
    public Field<UInt64> expiresAt() { return expiresAt; }

    public static CloudSessionSetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSessionSetRequest");
        Builder builder = builder();
        Object rawAccessToken = Wire.optional(object, "access_token");
        if (!Wire.isMissing(rawAccessToken)) {
            builder.accessToken(Wire.string(rawAccessToken, "CloudSessionSetRequest.access_token"));
        }
        Object rawApiBaseUrl = Wire.required(object, "api_base_url");
        builder.apiBaseUrl(Wire.string(rawApiBaseUrl, "CloudSessionSetRequest.api_base_url"));
        Object rawAuth = Wire.optional(object, "auth");
        if (!Wire.isMissing(rawAuth)) {
            builder.auth(rawAuth == null ? null : Wire.string(rawAuth, "CloudSessionSetRequest.auth"));
        }
        Object rawClientVersion = Wire.optional(object, "client_version");
        if (!Wire.isMissing(rawClientVersion)) {
            builder.clientVersion(rawClientVersion == null ? null : Wire.string(rawClientVersion, "CloudSessionSetRequest.client_version"));
        }
        Object rawExpiresAt = Wire.optional(object, "expires_at");
        if (!Wire.isMissing(rawExpiresAt)) {
            builder.expiresAt(Wire.uint64(rawExpiresAt, "CloudSessionSetRequest.expires_at"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "access_token", accessToken);
        Wire.put(object, "api_base_url", apiBaseUrl);
        Wire.put(object, "auth", auth);
        Wire.put(object, "client_version", clientVersion);
        Wire.put(object, "expires_at", expiresAt);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSessionSetRequest that)) return false;
        return Objects.equals(accessToken, that.accessToken) && Objects.equals(apiBaseUrl, that.apiBaseUrl) && Objects.equals(auth, that.auth) && Objects.equals(clientVersion, that.clientVersion) && Objects.equals(expiresAt, that.expiresAt);
    }

    @Override
    public int hashCode() { return Objects.hash(accessToken, apiBaseUrl, auth, clientVersion, expiresAt); }

    @Override
    public String toString() { return "CloudSessionSetRequest" + toWire(); }

    public static final class Builder {
        private Field<String> accessToken = Field.omitted();
        private String apiBaseUrl;
        private boolean apiBaseUrlSet;
        private Field<String> auth = Field.omitted();
        private Field<String> clientVersion = Field.omitted();
        private Field<UInt64> expiresAt = Field.omitted();

        public Builder accessToken(String value) {
            this.accessToken = Field.of(value);
            return this;
        }
        public Builder apiBaseUrl(String value) {
            this.apiBaseUrl = value;
            this.apiBaseUrlSet = true;
            return this;
        }
        public Builder auth(String value) {
            this.auth = Field.ofNullable(value);
            return this;
        }
        public Builder clientVersion(String value) {
            this.clientVersion = Field.ofNullable(value);
            return this;
        }
        public Builder expiresAt(UInt64 value) {
            this.expiresAt = Field.of(value);
            return this;
        }
        public CloudSessionSetRequest build() { return new CloudSessionSetRequest(this); }
    }
}
