// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionMediaResult implements WireValue {
    /** The image bytes in standard base64, at most 10 MiB decoded. */
    private final String data;
    /** The image type acpmux reported. */
    private final String mimeType;

    private AgentSessionMediaResult(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.mimeTypeSet) throw new IllegalArgumentException("mimeType is required");
        this.mimeType = builder.mimeType;
    }

    public static Builder builder() { return new Builder(); }

    public String data() { return data; }
    public String mimeType() { return mimeType; }

    public static AgentSessionMediaResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionMediaResult");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "AgentSessionMediaResult.data"));
        Object rawMimeType = Wire.required(object, "mimeType");
        builder.mimeType(rawMimeType == null ? null : Wire.string(rawMimeType, "AgentSessionMediaResult.mimeType"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "mimeType", mimeType);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionMediaResult that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(mimeType, that.mimeType);
    }

    @Override
    public int hashCode() { return Objects.hash(data, mimeType); }

    @Override
    public String toString() { return "AgentSessionMediaResult" + toWire(); }

    public static final class Builder {
        private String data;
        private boolean dataSet;
        private String mimeType;
        private boolean mimeTypeSet;

        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder mimeType(String value) {
            this.mimeType = value;
            this.mimeTypeSet = true;
            return this;
        }
        public AgentSessionMediaResult build() { return new AgentSessionMediaResult(this); }
    }
}
