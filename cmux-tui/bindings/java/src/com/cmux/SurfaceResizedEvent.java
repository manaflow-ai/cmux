package com.cmux;

public record SurfaceResizedEvent(long surface, int cols, int rows) implements CmuxEvent {
    public String event() {
        return "surface-resized";
    }
}
