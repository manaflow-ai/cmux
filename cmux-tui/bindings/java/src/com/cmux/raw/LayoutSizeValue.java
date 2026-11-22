// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class LayoutSizeValue implements WireValue {
    public enum Kind { LAYOUT_SIZE_SPLIT_RATIO, LAYOUT_SIZE_PANE_WIDTH }
    private final Kind kind;
    private final Object value;
    private LayoutSizeValue(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static LayoutSizeValue ofLayoutSizeSplitRatio(LayoutSizeSplitRatio value) {
        return new LayoutSizeValue(Kind.LAYOUT_SIZE_SPLIT_RATIO, value);
    }
    public boolean isLayoutSizeSplitRatio() { return kind == Kind.LAYOUT_SIZE_SPLIT_RATIO; }
    public LayoutSizeSplitRatio layoutSizeSplitRatio() {
        if (!isLayoutSizeSplitRatio()) throw new IllegalStateException("LayoutSizeValue contains " + kind);
        return (LayoutSizeSplitRatio) value;
    }

    public static LayoutSizeValue ofLayoutSizePaneWidth(LayoutSizePaneWidth value) {
        return new LayoutSizeValue(Kind.LAYOUT_SIZE_PANE_WIDTH, value);
    }
    public boolean isLayoutSizePaneWidth() { return kind == Kind.LAYOUT_SIZE_PANE_WIDTH; }
    public LayoutSizePaneWidth layoutSizePaneWidth() {
        if (!isLayoutSizePaneWidth()) throw new IllegalStateException("LayoutSizeValue contains " + kind);
        return (LayoutSizePaneWidth) value;
    }

    public static LayoutSizeValue fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofLayoutSizeSplitRatio(LayoutSizeSplitRatio.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofLayoutSizePaneWidth(LayoutSizePaneWidth.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no LayoutSizeValue variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof LayoutSizeValue that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "LayoutSizeValue[" + value + "]"; }
}
