package com.cmux;

public record VtStateEvent(long surface, int cols, int rows, String data) implements CmuxEvent {
    public String event() {
        return "vt-state";
    }
}
