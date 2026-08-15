// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutStack implements WireValue, Layout {
    private final UInt64 expanded;
    private final List<UInt64> panes;

    private LayoutStack(Builder builder) {
        if (!builder.expandedSet) throw new IllegalArgumentException("expanded is required");
        this.expanded = Wire.nonNull(builder.expanded, "expanded");
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 expanded() { return expanded; }
    public List<UInt64> panes() { return panes; }
    public String type() { return "stack"; }

    public static LayoutStack fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutStack");
        Builder builder = builder();
        Object rawExpanded = Wire.required(object, "expanded");
        builder.expanded(Wire.uint64(rawExpanded, "LayoutStack.expanded"));
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "LayoutStack.panes", item -> Wire.uint64(item, "LayoutStack.panes item")));
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "stack", "LayoutStack.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expanded", expanded);
        Wire.put(object, "panes", panes);
        Wire.put(object, "type", "stack");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutStack that)) return false;
        return Objects.equals(expanded, that.expanded) && Objects.equals(panes, that.panes);
    }

    @Override
    public int hashCode() { return Objects.hash(expanded, panes); }

    @Override
    public String toString() { return "LayoutStack" + toWire(); }

    public static final class Builder {
        private UInt64 expanded;
        private boolean expandedSet;
        private List<UInt64> panes;
        private boolean panesSet;

        public Builder expanded(UInt64 value) {
            this.expanded = value;
            this.expandedSet = true;
            return this;
        }
        public Builder panes(List<UInt64> value) {
            this.panes = value;
            this.panesSet = true;
            return this;
        }
        public LayoutStack build() { return new LayoutStack(this); }
    }
}
