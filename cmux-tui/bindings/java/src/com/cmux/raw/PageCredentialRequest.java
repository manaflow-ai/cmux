// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable page-credential request. Protocol v12; authority: local-admin. */
public final class PageCredentialRequest implements WireValue {
    private final Field<String> page;

    private PageCredentialRequest(Builder builder) {
        this.page = builder.page;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> page() { return page; }

    public static PageCredentialRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PageCredentialRequest");
        Builder builder = builder();
        Object rawPage = Wire.optional(object, "page");
        if (!Wire.isMissing(rawPage)) {
            builder.page(rawPage == null ? null : Wire.string(rawPage, "PageCredentialRequest.page"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "page", page);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PageCredentialRequest that)) return false;
        return Objects.equals(page, that.page);
    }

    @Override
    public int hashCode() { return Objects.hash(page); }

    @Override
    public String toString() { return "PageCredentialRequest" + toWire(); }

    public static final class Builder {
        private Field<String> page = Field.omitted();

        public Builder page(String value) {
            this.page = Field.ofNullable(value);
            return this;
        }
        public PageCredentialRequest build() { return new PageCredentialRequest(this); }
    }
}
