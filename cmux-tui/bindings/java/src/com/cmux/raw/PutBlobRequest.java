// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable put-blob request. Protocol v12; authority: control. */
public final class PutBlobRequest implements WireValue {
    private final String data;
    private final String mediaType;

    private PutBlobRequest(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.mediaTypeSet) throw new IllegalArgumentException("media_type is required");
        this.mediaType = Wire.nonNull(builder.mediaType, "media_type");
    }

    public static Builder builder() { return new Builder(); }

    public String data() { return data; }
    public String mediaType() { return mediaType; }

    public static PutBlobRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PutBlobRequest");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "PutBlobRequest.data"));
        Object rawMediaType = Wire.required(object, "media_type");
        builder.mediaType(Wire.string(rawMediaType, "PutBlobRequest.media_type"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "media_type", mediaType);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PutBlobRequest that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(mediaType, that.mediaType);
    }

    @Override
    public int hashCode() { return Objects.hash(data, mediaType); }

    @Override
    public String toString() { return "PutBlobRequest" + toWire(); }

    public static final class Builder {
        private String data;
        private boolean dataSet;
        private String mediaType;
        private boolean mediaTypeSet;

        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder mediaType(String value) {
            this.mediaType = value;
            this.mediaTypeSet = true;
            return this;
        }
        public PutBlobRequest build() { return new PutBlobRequest(this); }
    }
}
