package com.cmux;

public record EmptyEvent() implements CmuxEvent {
    public String event() {
        return "empty";
    }
}
