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
    private final String accessToken;
    private final String apiBaseUrl;
    private final Field<String> clientVersion;
    private final UInt64 expiresAt;

    private CloudSessionSetRequest(Builder builder) {
        if (!builder.accessTokenSet) throw new IllegalArgumentException("access_token is required");
        this.accessToken = Wire.nonNull(builder.accessToken, "access_token");
        if (!builder.apiBaseUrlSet) throw new IllegalArgumentException("api_base_url is required");
        this.apiBaseUrl = Wire.nonNull(builder.apiBaseUrl, "api_base_url");
        this.clientVersion = builder.clientVersion;
        if (!builder.expiresAtSet) throw new IllegalArgumentException("expires_at is required");
        this.expiresAt = Wire.nonNull(builder.expiresAt, "expires_at");
    }

    public static Builder builder() { return new Builder(); }

    public String accessToken() { return accessToken; }
    public String apiBaseUrl() { return apiBaseUrl; }
    public Field<String> clientVersion() { return clientVersion; }
    public UInt64 expiresAt() { return expiresAt; }

    public static CloudSessionSetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSessionSetRequest");
        Builder builder = builder();
        Object rawAccessToken = Wire.required(object, "access_token");
        builder.accessToken(Wire.string(rawAccessToken, "CloudSessionSetRequest.access_token"));
        Object rawApiBaseUrl = Wire.required(object, "api_base_url");
        builder.apiBaseUrl(Wire.string(rawApiBaseUrl, "CloudSessionSetRequest.api_base_url"));
        Object rawClientVersion = Wire.optional(object, "client_version");
        if (!Wire.isMissing(rawClientVersion)) {
            builder.clientVersion(rawClientVersion == null ? null : Wire.string(rawClientVersion, "CloudSessionSetRequest.client_version"));
        }
        Object rawExpiresAt = Wire.required(object, "expires_at");
        builder.expiresAt(Wire.uint64(rawExpiresAt, "CloudSessionSetRequest.expires_at"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "access_token", accessToken);
        Wire.put(object, "api_base_url", apiBaseUrl);
        Wire.put(object, "client_version", clientVersion);
        Wire.put(object, "expires_at", expiresAt);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSessionSetRequest that)) return false;
        return Objects.equals(accessToken, that.accessToken) && Objects.equals(apiBaseUrl, that.apiBaseUrl) && Objects.equals(clientVersion, that.clientVersion) && Objects.equals(expiresAt, that.expiresAt);
    }

    @Override
    public int hashCode() { return Objects.hash(accessToken, apiBaseUrl, clientVersion, expiresAt); }

    @Override
    public String toString() { return "CloudSessionSetRequest" + toWire(); }

    public static final class Builder {
        private String accessToken;
        private boolean accessTokenSet;
        private String apiBaseUrl;
        private boolean apiBaseUrlSet;
        private Field<String> clientVersion = Field.omitted();
        private UInt64 expiresAt;
        private boolean expiresAtSet;

        public Builder accessToken(String value) {
            this.accessToken = value;
            this.accessTokenSet = true;
            return this;
        }
        public Builder apiBaseUrl(String value) {
            this.apiBaseUrl = value;
            this.apiBaseUrlSet = true;
            return this;
        }
        public Builder clientVersion(String value) {
            this.clientVersion = Field.ofNullable(value);
            return this;
        }
        public Builder expiresAt(UInt64 value) {
            this.expiresAt = value;
            this.expiresAtSet = true;
            return this;
        }
        public CloudSessionSetRequest build() { return new CloudSessionSetRequest(this); }
    }
}
