package com.cmux;

public record ResizedEvent(long surface, int cols, int rows, String replay) implements CmuxEvent {
    public String event() {
        return "resized";
    }
}
