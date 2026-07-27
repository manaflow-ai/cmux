package com.cmux;

public record OverflowEvent(String error, String scope, Long surface) implements CmuxEvent {
    @Override
    public String event() {
        return "overflow";
    }
}
