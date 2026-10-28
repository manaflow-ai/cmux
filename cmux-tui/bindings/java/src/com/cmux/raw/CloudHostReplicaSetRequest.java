// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-host-replica-set request. Protocol v12; authority: local-admin. */
public final class CloudHostReplicaSetRequest implements WireValue {
    private final String apiBaseUrl;
    private final Field<String> clientVersion;
    private final UInt64 expiresAt;
    private final String hostName;
    private final String installToken;

    private CloudHostReplicaSetRequest(Builder builder) {
        if (!builder.apiBaseUrlSet) throw new IllegalArgumentException("api_base_url is required");
        this.apiBaseUrl = Wire.nonNull(builder.apiBaseUrl, "api_base_url");
        this.clientVersion = builder.clientVersion;
        if (!builder.expiresAtSet) throw new IllegalArgumentException("expires_at is required");
        this.expiresAt = Wire.nonNull(builder.expiresAt, "expires_at");
        if (!builder.hostNameSet) throw new IllegalArgumentException("host_name is required");
        this.hostName = Wire.nonNull(builder.hostName, "host_name");
        if (!builder.installTokenSet) throw new IllegalArgumentException("install_token is required");
        this.installToken = Wire.nonNull(builder.installToken, "install_token");
    }

    public static Builder builder() { return new Builder(); }

    public String apiBaseUrl() { return apiBaseUrl; }
    public Field<String> clientVersion() { return clientVersion; }
    public UInt64 expiresAt() { return expiresAt; }
    public String hostName() { return hostName; }
    public String installToken() { return installToken; }

    public static CloudHostReplicaSetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudHostReplicaSetRequest");
        Builder builder = builder();
        Object rawApiBaseUrl = Wire.required(object, "api_base_url");
        builder.apiBaseUrl(Wire.string(rawApiBaseUrl, "CloudHostReplicaSetRequest.api_base_url"));
        Object rawClientVersion = Wire.optional(object, "client_version");
        if (!Wire.isMissing(rawClientVersion)) {
            builder.clientVersion(rawClientVersion == null ? null : Wire.string(rawClientVersion, "CloudHostReplicaSetRequest.client_version"));
        }
        Object rawExpiresAt = Wire.required(object, "expires_at");
        builder.expiresAt(Wire.uint64(rawExpiresAt, "CloudHostReplicaSetRequest.expires_at"));
        Object rawHostName = Wire.required(object, "host_name");
        builder.hostName(Wire.string(rawHostName, "CloudHostReplicaSetRequest.host_name"));
        Object rawInstallToken = Wire.required(object, "install_token");
        builder.installToken(Wire.string(rawInstallToken, "CloudHostReplicaSetRequest.install_token"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "api_base_url", apiBaseUrl);
        Wire.put(object, "client_version", clientVersion);
        Wire.put(object, "expires_at", expiresAt);
        Wire.put(object, "host_name", hostName);
        Wire.put(object, "install_token", installToken);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudHostReplicaSetRequest that)) return false;
        return Objects.equals(apiBaseUrl, that.apiBaseUrl) && Objects.equals(clientVersion, that.clientVersion) && Objects.equals(expiresAt, that.expiresAt) && Objects.equals(hostName, that.hostName) && Objects.equals(installToken, that.installToken);
    }

    @Override
    public int hashCode() { return Objects.hash(apiBaseUrl, clientVersion, expiresAt, hostName, installToken); }

    @Override
    public String toString() { return "CloudHostReplicaSetRequest" + toWire(); }

    public static final class Builder {
        private String apiBaseUrl;
        private boolean apiBaseUrlSet;
        private Field<String> clientVersion = Field.omitted();
        private UInt64 expiresAt;
        private boolean expiresAtSet;
        private String hostName;
        private boolean hostNameSet;
        private String installToken;
        private boolean installTokenSet;

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
        public Builder hostName(String value) {
            this.hostName = value;
            this.hostNameSet = true;
            return this;
        }
        public Builder installToken(String value) {
            this.installToken = value;
            this.installTokenSet = true;
            return this;
        }
        public CloudHostReplicaSetRequest build() { return new CloudHostReplicaSetRequest(this); }
    }
}
