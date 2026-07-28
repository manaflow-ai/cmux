package com.cmux;

public record OutputEvent(long surface, String data) implements CmuxEvent {
    public String event() {
        return "output";
    }
}
