// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HomeInboxResult implements WireValue {
    private final String cloud;
    private final String me;
    private final List<HomeInboxRow> rows;

    private HomeInboxResult(Builder builder) {
        if (!builder.cloudSet) throw new IllegalArgumentException("cloud is required");
        this.cloud = Wire.nonNull(builder.cloud, "cloud");
        if (!builder.meSet) throw new IllegalArgumentException("me is required");
        this.me = Wire.nonNull(builder.me, "me");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
    }

    public static Builder builder() { return new Builder(); }

    public String cloud() { return cloud; }
    public String me() { return me; }
    public List<HomeInboxRow> rows() { return rows; }

    public static HomeInboxResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeInboxResult");
        Builder builder = builder();
        Object rawCloud = Wire.required(object, "cloud");
        builder.cloud(Wire.string(rawCloud, "HomeInboxResult.cloud"));
        Object rawMe = Wire.required(object, "me");
        builder.me(Wire.string(rawMe, "HomeInboxResult.me"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "HomeInboxResult.rows", item -> HomeInboxRow.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cloud", cloud);
        Wire.put(object, "me", me);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeInboxResult that)) return false;
        return Objects.equals(cloud, that.cloud) && Objects.equals(me, that.me) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cloud, me, rows); }

    @Override
    public String toString() { return "HomeInboxResult" + toWire(); }

    public static final class Builder {
        private String cloud;
        private boolean cloudSet;
        private String me;
        private boolean meSet;
        private List<HomeInboxRow> rows;
        private boolean rowsSet;

        public Builder cloud(String value) {
            this.cloud = value;
            this.cloudSet = true;
            return this;
        }
        public Builder me(String value) {
            this.me = value;
            this.meSet = true;
            return this;
        }
        public Builder rows(List<HomeInboxRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public HomeInboxResult build() { return new HomeInboxResult(this); }
    }
}
