// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppsTerminalLinksResult implements WireValue {
    private final List<AppTerminalLink> links;

    private AppsTerminalLinksResult(Builder builder) {
        if (!builder.linksSet) throw new IllegalArgumentException("links is required");
        this.links = List.copyOf(Wire.nonNull(builder.links, "links"));
    }

    public static Builder builder() { return new Builder(); }

    public List<AppTerminalLink> links() { return links; }

    public static AppsTerminalLinksResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsTerminalLinksResult");
        Builder builder = builder();
        Object rawLinks = Wire.required(object, "links");
        builder.links(Wire.array(rawLinks, "AppsTerminalLinksResult.links", item -> AppTerminalLink.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "links", links);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsTerminalLinksResult that)) return false;
        return Objects.equals(links, that.links);
    }

    @Override
    public int hashCode() { return Objects.hash(links); }

    @Override
    public String toString() { return "AppsTerminalLinksResult" + toWire(); }

    public static final class Builder {
        private List<AppTerminalLink> links;
        private boolean linksSet;

        public Builder links(List<AppTerminalLink> value) {
            this.links = value;
            this.linksSet = true;
            return this;
        }
        public AppsTerminalLinksResult build() { return new AppsTerminalLinksResult(this); }
    }
}
