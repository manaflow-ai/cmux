// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable register-browser-provider request. Protocol v10; authority: local-admin. */
public final class RegisterBrowserProviderRequest implements WireValue {
    private final BrowserProviderAuthentication authentication;
    private final Field<String> bearerToken;
    private final String endpoint;
    private final String providerId;
    private final List<BrowserProviderTarget> targets;

    private RegisterBrowserProviderRequest(Builder builder) {
        if (!builder.authenticationSet) throw new IllegalArgumentException("authentication is required");
        this.authentication = Wire.nonNull(builder.authentication, "authentication");
        this.bearerToken = builder.bearerToken;
        if (!builder.endpointSet) throw new IllegalArgumentException("endpoint is required");
        this.endpoint = Wire.nonNull(builder.endpoint, "endpoint");
        if (!builder.providerIdSet) throw new IllegalArgumentException("provider_id is required");
        this.providerId = Wire.nonNull(builder.providerId, "provider_id");
        if (!builder.targetsSet) throw new IllegalArgumentException("targets is required");
        this.targets = List.copyOf(Wire.nonNull(builder.targets, "targets"));
    }

    public static Builder builder() { return new Builder(); }

    public BrowserProviderAuthentication authentication() { return authentication; }
    public Field<String> bearerToken() { return bearerToken; }
    public String endpoint() { return endpoint; }
    public String providerId() { return providerId; }
    public List<BrowserProviderTarget> targets() { return targets; }

    public static RegisterBrowserProviderRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RegisterBrowserProviderRequest");
        Builder builder = builder();
        Object rawAuthentication = Wire.required(object, "authentication");
        builder.authentication(BrowserProviderAuthentication.fromWire(rawAuthentication));
        Object rawBearerToken = Wire.optional(object, "bearer_token");
        if (!Wire.isMissing(rawBearerToken)) {
            builder.bearerToken(rawBearerToken == null ? null : Wire.string(rawBearerToken, "RegisterBrowserProviderRequest.bearer_token"));
        }
        Object rawEndpoint = Wire.required(object, "endpoint");
        builder.endpoint(Wire.string(rawEndpoint, "RegisterBrowserProviderRequest.endpoint"));
        Object rawProviderId = Wire.required(object, "provider_id");
        builder.providerId(Wire.string(rawProviderId, "RegisterBrowserProviderRequest.provider_id"));
        Object rawTargets = Wire.required(object, "targets");
        builder.targets(Wire.array(rawTargets, "RegisterBrowserProviderRequest.targets", item -> BrowserProviderTarget.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authentication", authentication);
        Wire.put(object, "bearer_token", bearerToken);
        Wire.put(object, "endpoint", endpoint);
        Wire.put(object, "provider_id", providerId);
        Wire.put(object, "targets", targets);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RegisterBrowserProviderRequest that)) return false;
        return Objects.equals(authentication, that.authentication) && Objects.equals(bearerToken, that.bearerToken) && Objects.equals(endpoint, that.endpoint) && Objects.equals(providerId, that.providerId) && Objects.equals(targets, that.targets);
    }

    @Override
    public int hashCode() { return Objects.hash(authentication, bearerToken, endpoint, providerId, targets); }

    @Override
    public String toString() { return "RegisterBrowserProviderRequest" + toWire(); }

    public static final class Builder {
        private BrowserProviderAuthentication authentication;
        private boolean authenticationSet;
        private Field<String> bearerToken = Field.omitted();
        private String endpoint;
        private boolean endpointSet;
        private String providerId;
        private boolean providerIdSet;
        private List<BrowserProviderTarget> targets;
        private boolean targetsSet;

        public Builder authentication(BrowserProviderAuthentication value) {
            this.authentication = value;
            this.authenticationSet = true;
            return this;
        }
        public Builder bearerToken(String value) {
            this.bearerToken = Field.ofNullable(value);
            return this;
        }
        public Builder endpoint(String value) {
            this.endpoint = value;
            this.endpointSet = true;
            return this;
        }
        public Builder providerId(String value) {
            this.providerId = value;
            this.providerIdSet = true;
            return this;
        }
        public Builder targets(List<BrowserProviderTarget> value) {
            this.targets = value;
            this.targetsSet = true;
            return this;
        }
        public RegisterBrowserProviderRequest build() { return new RegisterBrowserProviderRequest(this); }
    }
}
