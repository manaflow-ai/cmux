// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable cloud-spare-warm-consent request. Protocol v12; authority: local-admin. */
public final class CloudSpareWarmConsentRequest implements WireValue {
    private final Field<Boolean> consent;

    private CloudSpareWarmConsentRequest(Builder builder) {
        this.consent = builder.consent;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> consent() { return consent; }

    public static CloudSpareWarmConsentRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloudSpareWarmConsentRequest");
        Builder builder = builder();
        Object rawConsent = Wire.optional(object, "consent");
        if (!Wire.isMissing(rawConsent)) {
            builder.consent(rawConsent == null ? null : Wire.bool(rawConsent, "CloudSpareWarmConsentRequest.consent"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "consent", consent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloudSpareWarmConsentRequest that)) return false;
        return Objects.equals(consent, that.consent);
    }

    @Override
    public int hashCode() { return Objects.hash(consent); }

    @Override
    public String toString() { return "CloudSpareWarmConsentRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> consent = Field.omitted();

        public Builder consent(Boolean value) {
            this.consent = Field.ofNullable(value);
            return this;
        }
        public CloudSpareWarmConsentRequest build() { return new CloudSpareWarmConsentRequest(this); }
    }
}
