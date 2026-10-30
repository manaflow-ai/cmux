// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable get-blob request. Protocol v12; authority: control. */
public final class GetBlobRequest implements WireValue {
    private final String blob;

    private GetBlobRequest(Builder builder) {
        if (!builder.blobSet) throw new IllegalArgumentException("blob is required");
        this.blob = Wire.nonNull(builder.blob, "blob");
    }

    public static Builder builder() { return new Builder(); }

    public String blob() { return blob; }

    public static GetBlobRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetBlobRequest");
        Builder builder = builder();
        Object rawBlob = Wire.required(object, "blob");
        builder.blob(Wire.string(rawBlob, "GetBlobRequest.blob"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "blob", blob);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetBlobRequest that)) return false;
        return Objects.equals(blob, that.blob);
    }

    @Override
    public int hashCode() { return Objects.hash(blob); }

    @Override
    public String toString() { return "GetBlobRequest" + toWire(); }

    public static final class Builder {
        private String blob;
        private boolean blobSet;

        public Builder blob(String value) {
            this.blob = value;
            this.blobSet = true;
            return this;
        }
        public GetBlobRequest build() { return new GetBlobRequest(this); }
    }
}
