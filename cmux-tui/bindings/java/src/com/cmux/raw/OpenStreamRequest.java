// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable open-stream request. Protocol v12; authority: local-admin. */
public final class OpenStreamRequest implements WireValue {
    private final String page;
    private final int stream;

    private OpenStreamRequest(Builder builder) {
        if (!builder.pageSet) throw new IllegalArgumentException("page is required");
        this.page = Wire.nonNull(builder.page, "page");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public String page() { return page; }
    public int stream() { return stream; }

    public static OpenStreamRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "OpenStreamRequest");
        Builder builder = builder();
        Object rawPage = Wire.required(object, "page");
        builder.page(Wire.string(rawPage, "OpenStreamRequest.page"));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "OpenStreamRequest.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "page", page);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof OpenStreamRequest that)) return false;
        return Objects.equals(page, that.page) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(page, stream); }

    @Override
    public String toString() { return "OpenStreamRequest" + toWire(); }

    public static final class Builder {
        private String page;
        private boolean pageSet;
        private Integer stream;
        private boolean streamSet;

        public Builder page(String value) {
            this.page = value;
            this.pageSet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public OpenStreamRequest build() { return new OpenStreamRequest(this); }
    }
}
