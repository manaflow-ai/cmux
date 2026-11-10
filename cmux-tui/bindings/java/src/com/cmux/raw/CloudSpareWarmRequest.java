// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-spare-warm request. Protocol v12; authority: local-admin. */
public final class CloudSpareWarmRequest implements WireValue {
    private final String accessToken;
    private final String account;
    private final String api;
    private final Field<String> claimed;
    private final Field<Boolean> consent;
    private final Field<Boolean> dogfood;
    private final String installToken;
    private final Field<List<String>> loginScopes;
    private final String platform;
    private final Field<Boolean> setting;
    private final Field<String> storedChoice;
    private final Field<String> team;

    private CloudSpareWarmRequest(Builder builder) {
        if (!builder.accessTokenSet) throw new IllegalArgumentException("access_token is required");
        this.accessToken = Wire.nonNull(builder.accessToken, "access_token");
        if (!builder.accountSet) throw new IllegalArgumentException("account is required");
        this.account = Wire.nonNull(builder.account, "account");
        if (!builder.apiSet) throw new IllegalArgumentException("api is required");
        this.api = Wire.nonNull(builder.api, "api");
        this.claimed = builder.claimed;
        this.consent = builder.consent;
        this.dogfood = builder.dogfood;
        if (!builder.installTokenSet) throw new IllegalArgumentException("install_token is required");
        this.installToken = Wire.nonNull(builder.installToken, "install_token");
        this.loginScopes = builder.loginScopes.map(value -> List.copyOf(value));
        if (!builder.platformSet) throw new IllegalArgumentException("platform is required");
        this.platform = Wire.nonNull(builder.platform, "platform");
        this.setting = builder.setting;
        this.storedChoice = builder.storedChoice;
        this.team = builder.team;
    }

    public static Builder builder() { return new Builder(); }

    public String accessToken() { return accessToken; }
    public String account() { return account; }
    public String api() { return api; }
    public Field<String> claimed() { return claimed; }
    public Field<Boolean> consent() { return consent; }
    public Field<Boolean> dogfood() { return dogfood; }
    public String installToken() { return installToken; }
    public Field<List<String>> loginScopes() { return loginScopes; }
    public String platform() { return platform; }
    public Field<Boolean> setting() { return setting; }
    public Field<String> storedChoice() { return storedChoice; }
    public Field<String> team() { return team; }

    public static CloudSpareWarmRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSpareWarmRequest");
        Builder builder = builder();
        Object rawAccessToken = Wire.required(object, "access_token");
        builder.accessToken(Wire.string(rawAccessToken, "CloudSpareWarmRequest.access_token"));
        Object rawAccount = Wire.required(object, "account");
        builder.account(Wire.string(rawAccount, "CloudSpareWarmRequest.account"));
        Object rawApi = Wire.required(object, "api");
        builder.api(Wire.string(rawApi, "CloudSpareWarmRequest.api"));
        Object rawClaimed = Wire.optional(object, "claimed");
        if (!Wire.isMissing(rawClaimed)) {
            builder.claimed(rawClaimed == null ? null : Wire.string(rawClaimed, "CloudSpareWarmRequest.claimed"));
        }
        Object rawConsent = Wire.optional(object, "consent");
        if (!Wire.isMissing(rawConsent)) {
            builder.consent(rawConsent == null ? null : Wire.bool(rawConsent, "CloudSpareWarmRequest.consent"));
        }
        Object rawDogfood = Wire.optional(object, "dogfood");
        if (!Wire.isMissing(rawDogfood)) {
            builder.dogfood(Wire.bool(rawDogfood, "CloudSpareWarmRequest.dogfood"));
        }
        Object rawInstallToken = Wire.required(object, "install_token");
        builder.installToken(Wire.string(rawInstallToken, "CloudSpareWarmRequest.install_token"));
        Object rawLoginScopes = Wire.optional(object, "login_scopes");
        if (!Wire.isMissing(rawLoginScopes)) {
            builder.loginScopes(Wire.array(rawLoginScopes, "CloudSpareWarmRequest.login_scopes", item -> Wire.string(item, "CloudSpareWarmRequest.login_scopes item")));
        }
        Object rawPlatform = Wire.required(object, "platform");
        builder.platform(Wire.string(rawPlatform, "CloudSpareWarmRequest.platform"));
        Object rawSetting = Wire.optional(object, "setting");
        if (!Wire.isMissing(rawSetting)) {
            builder.setting(rawSetting == null ? null : Wire.bool(rawSetting, "CloudSpareWarmRequest.setting"));
        }
        Object rawStoredChoice = Wire.optional(object, "stored_choice");
        if (!Wire.isMissing(rawStoredChoice)) {
            builder.storedChoice(rawStoredChoice == null ? null : Wire.string(rawStoredChoice, "CloudSpareWarmRequest.stored_choice"));
        }
        Object rawTeam = Wire.optional(object, "team");
        if (!Wire.isMissing(rawTeam)) {
            builder.team(rawTeam == null ? null : Wire.string(rawTeam, "CloudSpareWarmRequest.team"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "access_token", accessToken);
        Wire.put(object, "account", account);
        Wire.put(object, "api", api);
        Wire.put(object, "claimed", claimed);
        Wire.put(object, "consent", consent);
        Wire.put(object, "dogfood", dogfood);
        Wire.put(object, "install_token", installToken);
        Wire.put(object, "login_scopes", loginScopes);
        Wire.put(object, "platform", platform);
        Wire.put(object, "setting", setting);
        Wire.put(object, "stored_choice", storedChoice);
        Wire.put(object, "team", team);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSpareWarmRequest that)) return false;
        return Objects.equals(accessToken, that.accessToken) && Objects.equals(account, that.account) && Objects.equals(api, that.api) && Objects.equals(claimed, that.claimed) && Objects.equals(consent, that.consent) && Objects.equals(dogfood, that.dogfood) && Objects.equals(installToken, that.installToken) && Objects.equals(loginScopes, that.loginScopes) && Objects.equals(platform, that.platform) && Objects.equals(setting, that.setting) && Objects.equals(storedChoice, that.storedChoice) && Objects.equals(team, that.team);
    }

    @Override
    public int hashCode() { return Objects.hash(accessToken, account, api, claimed, consent, dogfood, installToken, loginScopes, platform, setting, storedChoice, team); }

    @Override
    public String toString() { return "CloudSpareWarmRequest" + toWire(); }

    public static final class Builder {
        private String accessToken;
        private boolean accessTokenSet;
        private String account;
        private boolean accountSet;
        private String api;
        private boolean apiSet;
        private Field<String> claimed = Field.omitted();
        private Field<Boolean> consent = Field.omitted();
        private Field<Boolean> dogfood = Field.omitted();
        private String installToken;
        private boolean installTokenSet;
        private Field<List<String>> loginScopes = Field.omitted();
        private String platform;
        private boolean platformSet;
        private Field<Boolean> setting = Field.omitted();
        private Field<String> storedChoice = Field.omitted();
        private Field<String> team = Field.omitted();

        public Builder accessToken(String value) {
            this.accessToken = value;
            this.accessTokenSet = true;
            return this;
        }
        public Builder account(String value) {
            this.account = value;
            this.accountSet = true;
            return this;
        }
        public Builder api(String value) {
            this.api = value;
            this.apiSet = true;
            return this;
        }
        public Builder claimed(String value) {
            this.claimed = Field.ofNullable(value);
            return this;
        }
        public Builder consent(Boolean value) {
            this.consent = Field.ofNullable(value);
            return this;
        }
        public Builder dogfood(Boolean value) {
            this.dogfood = Field.of(value);
            return this;
        }
        public Builder installToken(String value) {
            this.installToken = value;
            this.installTokenSet = true;
            return this;
        }
        public Builder loginScopes(List<String> value) {
            this.loginScopes = Field.of(value);
            return this;
        }
        public Builder platform(String value) {
            this.platform = value;
            this.platformSet = true;
            return this;
        }
        public Builder setting(Boolean value) {
            this.setting = Field.ofNullable(value);
            return this;
        }
        public Builder storedChoice(String value) {
            this.storedChoice = Field.ofNullable(value);
            return this;
        }
        public Builder team(String value) {
            this.team = Field.ofNullable(value);
            return this;
        }
        public CloudSpareWarmRequest build() { return new CloudSpareWarmRequest(this); }
    }
}
