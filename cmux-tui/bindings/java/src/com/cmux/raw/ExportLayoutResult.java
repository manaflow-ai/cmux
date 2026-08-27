// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ExportLayoutResult implements WireValue {
    private final Layout layout;
    private final List<ExportedPane> panes;

    private ExportLayoutResult(Builder builder) {
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
    }

    public static Builder builder() { return new Builder(); }

    public Layout layout() { return layout; }
    public List<ExportedPane> panes() { return panes; }

    public static ExportLayoutResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ExportLayoutResult");
        Builder builder = builder();
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "ExportLayoutResult.panes", item -> ExportedPane.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "layout", layout);
        Wire.put(object, "panes", panes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ExportLayoutResult that)) return false;
        return Objects.equals(layout, that.layout) && Objects.equals(panes, that.panes);
    }

    @Override
    public int hashCode() { return Objects.hash(layout, panes); }

    @Override
    public String toString() { return "ExportLayoutResult" + toWire(); }

    public static final class Builder {
        private Layout layout;
        private boolean layoutSet;
        private List<ExportedPane> panes;
        private boolean panesSet;

        public Builder layout(Layout value) {
            this.layout = value;
            this.layoutSet = true;
            return this;
        }
        public Builder panes(List<ExportedPane> value) {
            this.panes = value;
            this.panesSet = true;
            return this;
        }
        public ExportLayoutResult build() { return new ExportLayoutResult(this); }
    }
}
