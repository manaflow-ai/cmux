// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-set request. Protocol v12; authority: local-admin. */
public final class AppsSetRequest implements WireValue {
    private final String app;
    private final Field<Boolean> enabled;
    private final Field<AppGrant> grant;
    private final Field<Boolean> hidden;
    private final Field<AppHiddenAccess> hiddenAccess;
    private final String idempotencyKey;
    private final Field<Boolean> installed;
    private final Field<AppOrigin> origin;
    private final Field<Boolean> sandboxed;

    private AppsSetRequest(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.enabled = builder.enabled;
        this.grant = builder.grant;
        this.hidden = builder.hidden;
        this.hiddenAccess = builder.hiddenAccess;
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
        this.installed = builder.installed;
        this.origin = builder.origin;
        this.sandboxed = builder.sandboxed;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<Boolean> enabled() { return enabled; }
    public Field<AppGrant> grant() { return grant; }
    public Field<Boolean> hidden() { return hidden; }
    public Field<AppHiddenAccess> hiddenAccess() { return hiddenAccess; }
    public String idempotencyKey() { return idempotencyKey; }
    public Field<Boolean> installed() { return installed; }
    public Field<AppOrigin> origin() { return origin; }
    public Field<Boolean> sandboxed() { return sandboxed; }

    public static AppsSetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsSetRequest");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "AppsSetRequest.app"));
        Object rawEnabled = Wire.optional(object, "enabled");
        if (!Wire.isMissing(rawEnabled)) {
            builder.enabled(rawEnabled == null ? null : Wire.bool(rawEnabled, "AppsSetRequest.enabled"));
        }
        Object rawGrant = Wire.optional(object, "grant");
        if (!Wire.isMissing(rawGrant)) {
            builder.grant(rawGrant == null ? null : AppGrant.fromWire(rawGrant));
        }
        Object rawHidden = Wire.optional(object, "hidden");
        if (!Wire.isMissing(rawHidden)) {
            builder.hidden(rawHidden == null ? null : Wire.bool(rawHidden, "AppsSetRequest.hidden"));
        }
        Object rawHiddenAccess = Wire.optional(object, "hidden_access");
        if (!Wire.isMissing(rawHiddenAccess)) {
            builder.hiddenAccess(rawHiddenAccess == null ? null : AppHiddenAccess.fromWire(rawHiddenAccess));
        }
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "AppsSetRequest.idempotency_key"));
        Object rawInstalled = Wire.optional(object, "installed");
        if (!Wire.isMissing(rawInstalled)) {
            builder.installed(rawInstalled == null ? null : Wire.bool(rawInstalled, "AppsSetRequest.installed"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        Object rawSandboxed = Wire.optional(object, "sandboxed");
        if (!Wire.isMissing(rawSandboxed)) {
            builder.sandboxed(rawSandboxed == null ? null : Wire.bool(rawSandboxed, "AppsSetRequest.sandboxed"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "enabled", enabled);
        Wire.put(object, "grant", grant);
        Wire.put(object, "hidden", hidden);
        Wire.put(object, "hidden_access", hiddenAccess);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "installed", installed);
        Wire.put(object, "origin", origin);
        Wire.put(object, "sandboxed", sandboxed);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsSetRequest that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(enabled, that.enabled) && Objects.equals(grant, that.grant) && Objects.equals(hidden, that.hidden) && Objects.equals(hiddenAccess, that.hiddenAccess) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(installed, that.installed) && Objects.equals(origin, that.origin) && Objects.equals(sandboxed, that.sandboxed);
    }

    @Override
    public int hashCode() { return Objects.hash(app, enabled, grant, hidden, hiddenAccess, idempotencyKey, installed, origin, sandboxed); }

    @Override
    public String toString() { return "AppsSetRequest" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<Boolean> enabled = Field.omitted();
        private Field<AppGrant> grant = Field.omitted();
        private Field<Boolean> hidden = Field.omitted();
        private Field<AppHiddenAccess> hiddenAccess = Field.omitted();
        private String idempotencyKey;
        private boolean idempotencyKeySet;
        private Field<Boolean> installed = Field.omitted();
        private Field<AppOrigin> origin = Field.omitted();
        private Field<Boolean> sandboxed = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder enabled(Boolean value) {
            this.enabled = Field.ofNullable(value);
            return this;
        }
        public Builder grant(AppGrant value) {
            this.grant = Field.ofNullable(value);
            return this;
        }
        public Builder hidden(Boolean value) {
            this.hidden = Field.ofNullable(value);
            return this;
        }
        public Builder hiddenAccess(AppHiddenAccess value) {
            this.hiddenAccess = Field.ofNullable(value);
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = value;
            this.idempotencyKeySet = true;
            return this;
        }
        public Builder installed(Boolean value) {
            this.installed = Field.ofNullable(value);
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public Builder sandboxed(Boolean value) {
            this.sandboxed = Field.ofNullable(value);
            return this;
        }
        public AppsSetRequest build() { return new AppsSetRequest(this); }
    }
}
