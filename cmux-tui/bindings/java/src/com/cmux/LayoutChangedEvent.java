package com.cmux;

public record LayoutChangedEvent(long screen) implements CmuxEvent {
    public String event() {
        return "layout-changed";
    }
}
